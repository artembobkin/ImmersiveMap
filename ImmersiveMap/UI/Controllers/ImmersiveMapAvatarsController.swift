// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import CoreGraphics
import simd
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct AvatarsSnapshot {
    public let markers: [AvatarMarker]
    public let removedIds: [UInt64]
    public let imageUpdateIds: [UInt64]
    public let version: UInt64
}

/// Public thread-safe owner of the avatar markers supplied by app code.
/// Collects marker mutations into snapshots for the renderer and selection runtime.
/// Thread-safe (`@unchecked Sendable`): all mutable state is serialized by
/// `lock`, so markers can be updated from any thread.
public final class ImmersiveMapAvatarsController: @unchecked Sendable {
    /// A group of merged markers: the members are hidden from the map, and a
    /// single merged marker is drawn instead with averaged geo, a bubble counter,
    /// and a cycling image of the members.
    private struct MergedAvatarGroup {
        var memberIDs: [UInt64]
        /// Holds the merged marker's appearance (isSelected, borderColor, ...);
        /// the coordinate and image are computed from the members.
        var template: AvatarMarker
        var imageCycleInterval: TimeInterval
        var imageCycleIndex: Int = 0
    }

    private let lock = NSLock()
    private let imageLoader: @Sendable (URL) async throws -> CGImage
    private var markersById: [UInt64: AvatarMarker] = [:]
    private var mergedGroupsById: [UInt64: MergedAvatarGroup] = [:]
    private var imageCycleTimersById: [UInt64: DispatchSourceTimer] = [:]
    private var removedIds: Set<UInt64> = []
    private var imageUpdateIds: Set<UInt64> = []
    private var loadingRemoteImageURLsById: [UInt64: URL] = [:]
    private var version: UInt64 = 0
    private var hasChanges: Bool = false
    private var changeHandler: (() -> Void)?
    private weak var changeHandlerOwner: AnyObject?

    public convenience init() {
        self.init(imageLoader: { url in
            try await AvatarMarkerImageLoader.loadCGImage(from: url)
        })
    }

    init(imageLoader: @escaping @Sendable (URL) async throws -> CGImage) {
        self.imageLoader = imageLoader
    }

    public func add(_ marker: AvatarMarker) {
        upsert([marker])
    }

    public func add(_ markers: [AvatarMarker]) {
        upsert(markers)
    }

    /// Fully replaces the map content; all merged groups are dissolved.
    public func set(_ markers: [AvatarMarker]) {
        lock.lock()
        dissolveAllMergedGroupsLocked()
        markersById = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, $0) })
        removedIds.removeAll(keepingCapacity: true)
        imageUpdateIds = Set(markersById.keys)
        let remoteImageLoadRequests = remoteImageLoadRequestsLocked(for: markers)
        markChangedLocked()
        lock.unlock()
        scheduleRemoteImageLoads(remoteImageLoadRequests)
        notifyChanged()
    }

    public func upsert(_ markers: [AvatarMarker]) {
        lock.lock()
        for marker in markers {
            assert(mergedGroupsById[marker.id] == nil,
                   "Marker id \(marker.id) collides with a merged marker id.")
            guard mergedGroupsById[marker.id] == nil else {
                continue
            }
            markersById[marker.id] = marker
            removedIds.remove(marker.id)
            imageUpdateIds.insert(marker.id)
        }
        let remoteImageLoadRequests = remoteImageLoadRequestsLocked(for: markers)
        markChangedLocked()
        lock.unlock()
        scheduleRemoteImageLoads(remoteImageLoadRequests)
        notifyChanged()
    }

    /// Merges existing markers into a single merged marker `mergedID`:
    /// the members are hidden from the map, and a shared marker is drawn instead
    /// with the members' averaged geo (live: a member's `move` shifts the
    /// average), a bubble counter of the member count, and an image that cycles
    /// between members every `imageCycleInterval` seconds (0 disables the cycle).
    ///
    /// The members stay in the controller: they can be moved and updated, and
    /// `unmerge(mergedID:)` returns them to the map. Calling `merge` again with
    /// the same `mergedID` replaces the group membership. `mergedID` must not
    /// collide with a regular marker id. A marker already in another group is ignored.
    public func merge(ids: [UInt64],
                      mergedID: UInt64,
                      imageCycleInterval: TimeInterval = 3.0) {
        lock.lock()
        precondition(markersById[mergedID] == nil,
                     "mergedID must not collide with an existing marker id.")
        var memberIDsInOtherGroups = Set<UInt64>()
        for (groupID, group) in mergedGroupsById where groupID != mergedID {
            memberIDsInOtherGroups.formUnion(group.memberIDs)
        }

        var memberIDs: [UInt64] = []
        for id in ids where markersById[id] != nil
            && memberIDsInOtherGroups.contains(id) == false
            && memberIDs.contains(id) == false {
            memberIDs.append(id)
        }
        guard let firstMember = memberIDs.first.flatMap({ markersById[$0] }) else {
            lock.unlock()
            return
        }

        let template = mergedGroupsById[mergedID]?.template
            ?? AvatarMarker(id: mergedID,
                            coordinate: firstMember.coordinate,
                            image: firstMember.image,
                            borderColor: firstMember.borderColor,
                            screenSizeScale: firstMember.screenSizeScale,
                            drawPriority: firstMember.drawPriority)
        mergedGroupsById[mergedID] = MergedAvatarGroup(memberIDs: memberIDs,
                                                       template: template,
                                                       imageCycleInterval: imageCycleInterval)
        // The members leave the map as standalone markers.
        removedIds.formUnion(memberIDs)
        removedIds.remove(mergedID)
        imageUpdateIds.insert(mergedID)
        rescheduleImageCycleTimerLocked(mergedID: mergedID)
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    /// Dissolves a merged marker: the members return to the map at their
    /// current coordinates.
    public func unmerge(mergedID: UInt64) {
        lock.lock()
        guard let group = mergedGroupsById.removeValue(forKey: mergedID) else {
            lock.unlock()
            return
        }

        cancelImageCycleTimerLocked(mergedID: mergedID)
        removedIds.insert(mergedID)
        imageUpdateIds.formUnion(group.memberIDs.filter { markersById[$0] != nil })
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    /// Membership of a merged marker in image-cycle order; nil if the group does not exist.
    public func mergedMemberIDs(mergedID: UInt64) -> [UInt64]? {
        lock.lock()
        defer { lock.unlock() }
        return mergedGroupsById[mergedID]?.memberIDs
    }

    public func move(id: UInt64, to coordinate: GeoCoordinate) {
        lock.lock()
        guard var marker = markersById[id] else {
            lock.unlock()
            return
        }
        marker.coordinate = coordinate
        markersById[id] = marker
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    public func move(id: UInt64, latitude: Double, longitude: Double) {
        move(id: id, to: GeoCoordinate(latitude: latitude, longitude: longitude))
    }

    func marker(id: UInt64) -> AvatarMarker? {
        lock.lock()
        defer { lock.unlock() }
        if mergedGroupsById[id] != nil {
            return makeMergedMarkerLocked(mergedID: id)
        }
        return markersById[id]
    }

    public func update(id: UInt64,
                       image: CGImage? = nil,
                       borderColor: SIMD4<Float>? = nil,
                       isSelected: Bool? = nil) {
        lock.lock()
        // For a merged marker the template is updated: the member cycle owns the
        // image, so image is ignored for a group.
        if var group = mergedGroupsById[id] {
            if let borderColor {
                group.template.borderColor = borderColor
            }
            if let isSelected {
                group.template.isSelected = isSelected
            }
            mergedGroupsById[id] = group
            markChangedLocked()
            lock.unlock()
            notifyChanged()
            return
        }

        guard var marker = markersById[id] else {
            lock.unlock()
            return
        }
        if let image {
            marker.image = image
            marker.imageSource = .cgImage(image)
            imageUpdateIds.insert(id)
        }
        if let borderColor {
            marker.borderColor = borderColor
        }
        if let isSelected {
            marker.isSelected = isSelected
        }
        markersById[id] = marker
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

#if canImport(UIKit)
    public func update(id: UInt64,
                       image: UIImage,
                       borderColor: SIMD4<Float>? = nil,
                       isSelected: Bool? = nil) {
        guard let cgImage = image.cgImage else {
            preconditionFailure("UIImage must have CGImage backing.")
        }
        update(id: id,
               image: cgImage,
               borderColor: borderColor,
               isSelected: isSelected)
    }
#elseif canImport(AppKit)
    public func update(id: UInt64,
                       image: NSImage,
                       borderColor: SIMD4<Float>? = nil,
                       isSelected: Bool? = nil) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            preconditionFailure("NSImage must be convertible to CGImage.")
        }
        update(id: id,
               image: cgImage,
               borderColor: borderColor,
               isSelected: isSelected)
    }
#endif

    /// Removes markers. For a merged marker id the whole group is removed along
    /// with its members; removing a member excludes it from its group (an emptied
    /// group is dissolved).
    public func remove(ids: [UInt64]) {
        lock.lock()
        for id in ids {
            if let group = mergedGroupsById.removeValue(forKey: id) {
                cancelImageCycleTimerLocked(mergedID: id)
                for memberID in group.memberIDs {
                    markersById.removeValue(forKey: memberID)
                    removedIds.insert(memberID)
                    imageUpdateIds.remove(memberID)
                    loadingRemoteImageURLsById.removeValue(forKey: memberID)
                }
            }
            markersById.removeValue(forKey: id)
            removedIds.insert(id)
            imageUpdateIds.remove(id)
            loadingRemoteImageURLsById.removeValue(forKey: id)
            removeMemberFromGroupsLocked(memberID: id)
        }
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    private func removeMemberFromGroupsLocked(memberID: UInt64) {
        for (mergedID, var group) in mergedGroupsById where group.memberIDs.contains(memberID) {
            group.memberIDs.removeAll { $0 == memberID }
            if group.memberIDs.isEmpty {
                mergedGroupsById.removeValue(forKey: mergedID)
                cancelImageCycleTimerLocked(mergedID: mergedID)
                removedIds.insert(mergedID)
            } else {
                mergedGroupsById[mergedID] = group
                rescheduleImageCycleTimerLocked(mergedID: mergedID)
            }
        }
    }

    public func remove(id: UInt64) {
        remove(ids: [id])
    }

    public func clear() {
        lock.lock()
        removedIds.formUnion(markersById.keys)
        removedIds.formUnion(mergedGroupsById.keys)
        dissolveAllMergedGroupsLocked()
        markersById.removeAll(keepingCapacity: true)
        imageUpdateIds.removeAll(keepingCapacity: true)
        loadingRemoteImageURLsById.removeAll(keepingCapacity: true)
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    private func dissolveAllMergedGroupsLocked() {
        for mergedID in mergedGroupsById.keys {
            cancelImageCycleTimerLocked(mergedID: mergedID)
        }
        mergedGroupsById.removeAll(keepingCapacity: true)
    }

    func consumeSnapshot() -> AvatarsSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard hasChanges else { return nil }
        hasChanges = false
        let snapshot = AvatarsSnapshot(markers: visibleMarkersLocked(),
                                       removedIds: Array(removedIds),
                                       imageUpdateIds: Array(imageUpdateIds),
                                       version: version)
        removedIds.removeAll(keepingCapacity: true)
        imageUpdateIds.removeAll(keepingCapacity: true)
        return snapshot
    }

    /// Visible markers: regular ones excluding group members, plus merged markers.
    private func visibleMarkersLocked() -> [AvatarMarker] {
        var mergedMemberIDs = Set<UInt64>()
        for group in mergedGroupsById.values {
            mergedMemberIDs.formUnion(group.memberIDs)
        }

        var markers: [AvatarMarker] = []
        markers.reserveCapacity(markersById.count + mergedGroupsById.count)
        for marker in markersById.values where mergedMemberIDs.contains(marker.id) == false {
            markers.append(marker)
        }
        for mergedID in mergedGroupsById.keys {
            if let merged = makeMergedMarkerLocked(mergedID: mergedID) {
                markers.append(merged)
            }
        }
        return markers
    }

    /// The group's merged marker: averaged member geo, the image of the current
    /// cycle step, and a bubble counter; appearance (selection, border) from the template.
    private func makeMergedMarkerLocked(mergedID: UInt64) -> AvatarMarker? {
        guard let group = mergedGroupsById[mergedID] else {
            return nil
        }

        let members = group.memberIDs.compactMap { markersById[$0] }
        guard members.isEmpty == false else {
            return nil
        }

        let cycleMember = members[group.imageCycleIndex % members.count]
        var merged = group.template
        merged.coordinate = Self.averageCoordinate(of: members.map(\.coordinate))
        merged.image = cycleMember.image
        merged.imageSource = .cgImage(cycleMember.image)
        merged.batteryBadge = nil
        merged.speedBadge = nil
        merged.countBadge = AvatarCountBadge(count: members.count)
        return merged
    }

    /// Average geo over unit vectors on the sphere: correct near the antimeridian
    /// and the poles, unlike an arithmetic mean of latitudes/longitudes.
    static func averageCoordinate(of coordinates: [GeoCoordinate]) -> GeoCoordinate {
        guard coordinates.count > 1 else {
            return coordinates.first ?? GeoCoordinate(latitude: 0, longitude: 0)
        }

        var sum = SIMD3<Double>.zero
        for coordinate in coordinates {
            let latitude = coordinate.latitude * .pi / 180.0
            let longitude = coordinate.longitude * .pi / 180.0
            let cosLatitude = cos(latitude)
            sum += SIMD3<Double>(cosLatitude * cos(longitude),
                                 cosLatitude * sin(longitude),
                                 sin(latitude))
        }

        let length = simd_length(sum)
        guard length > Double.leastNormalMagnitude else {
            return coordinates[0]
        }

        let mean = sum / length
        let latitude = atan2(mean.z, sqrt(mean.x * mean.x + mean.y * mean.y))
        let longitude = atan2(mean.y, mean.x)
        return GeoCoordinate(latitude: latitude * 180.0 / .pi,
                             longitude: longitude * 180.0 / .pi)
    }

    /// One step of a merged marker's image cycle; driven by the group's timer.
    func advanceMergedImageCycle(mergedID: UInt64) {
        lock.lock()
        guard var group = mergedGroupsById[mergedID],
              group.memberIDs.count > 1 else {
            lock.unlock()
            return
        }

        group.imageCycleIndex &+= 1
        mergedGroupsById[mergedID] = group
        imageUpdateIds.insert(mergedID)
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    private func rescheduleImageCycleTimerLocked(mergedID: UInt64) {
        cancelImageCycleTimerLocked(mergedID: mergedID)
        guard let group = mergedGroupsById[mergedID],
              group.imageCycleInterval > 0,
              group.memberIDs.count > 1 else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + group.imageCycleInterval,
                       repeating: group.imageCycleInterval)
        timer.setEventHandler { [weak self] in
            self?.advanceMergedImageCycle(mergedID: mergedID)
        }
        timer.activate()
        imageCycleTimersById[mergedID] = timer
    }

    private func cancelImageCycleTimerLocked(mergedID: UInt64) {
        imageCycleTimersById.removeValue(forKey: mergedID)?.cancel()
    }

    func setChangeHandler(_ handler: (() -> Void)?, owner: AnyObject) {
        lock.lock()
        changeHandler = handler
        changeHandlerOwner = owner
        lock.unlock()
    }

    /// Clears the handler only if `owner` still owns it: tearing down an old
    /// host view must not detach the controller from a new view that has
    /// already rebound it to itself.
    func clearChangeHandler(ownedBy owner: AnyObject) {
        lock.lock()
        if changeHandlerOwner === owner {
            changeHandler = nil
            changeHandlerOwner = nil
        }
        lock.unlock()
    }

    func markSnapshotDirty() {
        lock.lock()
        markSnapshotDirtyLocked()
        lock.unlock()
    }

    private func markChangedLocked() {
        version &+= 1
        hasChanges = true
    }

    private func markSnapshotDirtyLocked() {
        imageUpdateIds.formUnion(markersById.keys)
        markChangedLocked()
    }

    private func remoteImageLoadRequestsLocked(for markers: [AvatarMarker]) -> [(id: UInt64, url: URL)] {
        var requests: [(id: UInt64, url: URL)] = []
        requests.reserveCapacity(markers.count)
        for marker in markers {
            guard let remoteURL = marker.imageSource.remoteURL else {
                loadingRemoteImageURLsById.removeValue(forKey: marker.id)
                continue
            }
            guard loadingRemoteImageURLsById[marker.id] != remoteURL else {
                continue
            }
            loadingRemoteImageURLsById[marker.id] = remoteURL
            requests.append((id: marker.id, url: remoteURL))
        }
        return requests
    }

    private func scheduleRemoteImageLoads(_ requests: [(id: UInt64, url: URL)]) {
        for request in requests {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let image = try await imageLoader(request.url)
                    applyRemoteImage(image, markerID: request.id, url: request.url)
                } catch {
                    finishRemoteImageLoad(markerID: request.id, url: request.url)
                }
            }
        }
    }

    private func applyRemoteImage(_ image: CGImage, markerID: UInt64, url: URL) {
        lock.lock()
        var shouldNotify = false
        if var marker = markersById[markerID],
           marker.imageSource.remoteURL == url {
            marker.image = image
            markersById[markerID] = marker
            imageUpdateIds.insert(markerID)
            markChangedLocked()
            shouldNotify = true
        }
        if loadingRemoteImageURLsById[markerID] == url {
            loadingRemoteImageURLsById.removeValue(forKey: markerID)
        }
        lock.unlock()

        if shouldNotify {
            notifyChanged()
        }
    }

    private func finishRemoteImageLoad(markerID: UInt64, url: URL) {
        lock.lock()
        if loadingRemoteImageURLsById[markerID] == url {
            loadingRemoteImageURLsById.removeValue(forKey: markerID)
        }
        lock.unlock()
    }

    private func notifyChanged() {
        lock.lock()
        let changeHandler = changeHandler
        lock.unlock()

        changeHandler?()
    }

    deinit {
        for timer in imageCycleTimersById.values {
            timer.cancel()
        }
    }
}

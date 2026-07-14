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

/// Public thread-safe owner для avatar markers, которые передает app code.
/// Собирает marker mutations в snapshots для renderer и selection runtime.
public final class ImmersiveMapAvatarsController {
    /// Группа объединённых маркеров: участники скрыты с карты, вместо них
    /// рисуется один merged-маркер с усреднённым гео, bubble-счётчиком и
    /// циклической сменой картинки участников.
    private struct MergedAvatarGroup {
        var memberIDs: [UInt64]
        /// Хранит внешний вид merged-маркера (isSelected, borderColor, ...);
        /// координата и картинка вычисляются из участников.
        var template: AvatarMarker
        var imageCycleInterval: TimeInterval
        var imageCycleIndex: Int = 0
    }

    private let lock = NSLock()
    private let imageLoader: (URL) async throws -> CGImage
    private var markersById: [UInt64: AvatarMarker] = [:]
    private var mergedGroupsById: [UInt64: MergedAvatarGroup] = [:]
    private var imageCycleTimersById: [UInt64: DispatchSourceTimer] = [:]
    private var removedIds: Set<UInt64> = []
    private var imageUpdateIds: Set<UInt64> = []
    private var loadingRemoteImageURLsById: [UInt64: URL] = [:]
    private var version: UInt64 = 0
    private var hasChanges: Bool = false
    private var changeHandler: (() -> Void)?

    public convenience init() {
        self.init(imageLoader: { url in
            try await AvatarMarkerImageLoader.loadCGImage(from: url)
        })
    }

    init(imageLoader: @escaping (URL) async throws -> CGImage) {
        self.imageLoader = imageLoader
    }

    public func add(_ marker: AvatarMarker) {
        upsert([marker])
    }

    public func add(_ markers: [AvatarMarker]) {
        upsert(markers)
    }

    /// Полностью заменяет контент карты; все merged-группы распускаются.
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

    /// Объединяет существующие маркеры в один merged-маркер `mergedID`:
    /// участники скрываются с карты, вместо них рисуется общий маркер с
    /// усреднённым гео участников (живым: `move` участника сдвигает среднее),
    /// bubble-счётчиком количества и картинкой, циклически меняющейся между
    /// участниками каждые `imageCycleInterval` секунд (0 выключает цикл).
    ///
    /// Участники остаются в контроллере: их можно двигать и обновлять, а
    /// `unmerge(mergedID:)` возвращает их на карту. Повторный `merge` с тем же
    /// `mergedID` заменяет состав группы. `mergedID` не должен совпадать с id
    /// обычного маркера. Маркер, уже состоящий в другой группе, игнорируется.
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
        // Участники уходят с карты как самостоятельные маркеры.
        removedIds.formUnion(memberIDs)
        removedIds.remove(mergedID)
        imageUpdateIds.insert(mergedID)
        rescheduleImageCycleTimerLocked(mergedID: mergedID)
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    /// Распускает merged-маркер: участники возвращаются на карту на свои
    /// актуальные координаты.
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

    /// Состав merged-маркера в порядке цикла картинок; nil, если группы нет.
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
        // У merged-маркера обновляется template: картинкой владеет цикл
        // участников, поэтому image для группы игнорируется.
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

    /// Удаляет маркеры. Для id merged-маркера удаляется вся группа вместе с
    /// участниками; удаление участника исключает его из группы (опустевшая
    /// группа распускается).
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

    /// Видимые маркеры: обычные без участников групп, плюс merged-маркеры.
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

    /// Merged-маркер группы: усреднённое гео участников, картинка текущего
    /// шага цикла и bubble-счётчик; внешний вид (selection, рамка) из template.
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

    /// Среднее гео по единичным векторам на сфере: корректно у антимеридиана
    /// и полюсов, в отличие от арифметического среднего широт/долгот.
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

    /// Шаг цикла картинок merged-маркера; дергается таймером группы.
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

    func setChangeHandler(_ handler: (() -> Void)?) {
        lock.lock()
        changeHandler = handler
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

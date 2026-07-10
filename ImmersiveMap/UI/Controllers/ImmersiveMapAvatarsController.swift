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
    private let lock = NSLock()
    private let imageLoader: (URL) async throws -> CGImage
    private var markersById: [UInt64: AvatarMarker] = [:]
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

    public func set(_ markers: [AvatarMarker]) {
        lock.lock()
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
        return markersById[id]
    }

    public func update(id: UInt64,
                       image: CGImage? = nil,
                       borderColor: SIMD4<Float>? = nil,
                       isSelected: Bool? = nil) {
        lock.lock()
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

    public func remove(ids: [UInt64]) {
        lock.lock()
        for id in ids {
            markersById.removeValue(forKey: id)
            removedIds.insert(id)
            imageUpdateIds.remove(id)
            loadingRemoteImageURLsById.removeValue(forKey: id)
        }
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    public func remove(id: UInt64) {
        remove(ids: [id])
    }

    public func clear() {
        lock.lock()
        removedIds.formUnion(markersById.keys)
        markersById.removeAll(keepingCapacity: true)
        imageUpdateIds.removeAll(keepingCapacity: true)
        loadingRemoteImageURLsById.removeAll(keepingCapacity: true)
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    func consumeSnapshot() -> AvatarsSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard hasChanges else { return nil }
        hasChanges = false
        let snapshot = AvatarsSnapshot(markers: Array(markersById.values),
                                       removedIds: Array(removedIds),
                                       imageUpdateIds: Array(imageUpdateIds),
                                       version: version)
        removedIds.removeAll(keepingCapacity: true)
        imageUpdateIds.removeAll(keepingCapacity: true)
        return snapshot
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
}

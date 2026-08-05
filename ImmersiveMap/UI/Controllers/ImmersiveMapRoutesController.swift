// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Public thread-safe owner of the routes supplied by app code.
/// Collects route mutations into snapshots for the renderer.
/// Thread-safe (`@unchecked Sendable`): all mutable state is serialized by
/// `lock`, so routes can be updated from any thread.
public final class ImmersiveMapRoutesController: @unchecked Sendable {
    private let lock = NSLock()
    private var routesById: [UInt64: ImmersiveMapRoute] = [:]
    private var removedIds: Set<UInt64> = []
    private var progressAnimationsById: [UInt64: RouteProgressAnimationRequest] = [:]
    private var version: UInt64 = 0
    private var hasChanges: Bool = false
    private var changeHandler: (() -> Void)?
    private weak var changeHandlerOwner: AnyObject?

    public init() {}

    public func add(_ route: ImmersiveMapRoute) {
        upsert([route])
    }

    public func add(_ routes: [ImmersiveMapRoute]) {
        upsert(routes)
    }

    /// Fully replaces the drawn routes. Descriptor changes snap; progress
    /// changes of surviving ids snap too unless requested through
    /// `setProgress(id:_:duration:)`.
    public func set(_ routes: [ImmersiveMapRoute]) {
        lock.lock()
        let newIds = Set(routes.map(\.id))
        removedIds.formUnion(routesById.keys.filter { newIds.contains($0) == false })
        // Last wins on a repeated id, matching `upsert`, rather than trapping.
        var replacement: [UInt64: ImmersiveMapRoute] = [:]
        replacement.reserveCapacity(routes.count)
        for route in routes {
            replacement[route.id] = route
        }
        routesById = replacement
        removedIds.subtract(newIds)
        progressAnimationsById.removeAll(keepingCapacity: true)
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    public func upsert(_ routes: [ImmersiveMapRoute]) {
        lock.lock()
        for route in routes {
            routesById[route.id] = route
            removedIds.remove(route.id)
        }
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    /// Sets how much of the route is drawn from its start. A positive
    /// `duration` animates the change, which is the "line draws itself" effect.
    public func setProgress(id: UInt64, _ progress: Double, duration: TimeInterval = 0) {
        lock.lock()
        guard var route = routesById[id] else {
            lock.unlock()
            return
        }
        // The start is taken from what the route shows now, or from the start
        // an unconsumed request already recorded: two setProgress calls between
        // frames animate once, from where the line actually was.
        let startProgress = progressAnimationsById[id]?.startProgress ?? route.progress
        route.progress = min(max(progress, 0), 1)
        routesById[id] = route
        progressAnimationsById[id] = RouteProgressAnimationRequest(
            startProgress: min(max(startProgress, 0), 1),
            duration: max(0, duration))
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    public func remove(ids: [UInt64]) {
        lock.lock()
        for id in ids {
            routesById.removeValue(forKey: id)
            removedIds.insert(id)
            progressAnimationsById.removeValue(forKey: id)
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
        removedIds.formUnion(routesById.keys)
        routesById.removeAll(keepingCapacity: true)
        progressAnimationsById.removeAll(keepingCapacity: true)
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    func consumeSnapshot() -> RoutesSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard hasChanges else { return nil }
        hasChanges = false
        let snapshot = RoutesSnapshot(routes: Array(routesById.values),
                                      progressAnimationsById: progressAnimationsById,
                                      removedIds: Array(removedIds),
                                      version: version)
        removedIds.removeAll(keepingCapacity: true)
        progressAnimationsById.removeAll(keepingCapacity: true)
        return snapshot
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
        markChangedLocked()
        lock.unlock()
    }

    private func markChangedLocked() {
        version &+= 1
        hasChanges = true
    }

    private func notifyChanged() {
        lock.lock()
        let changeHandler = changeHandler
        lock.unlock()

        changeHandler?()
    }
}

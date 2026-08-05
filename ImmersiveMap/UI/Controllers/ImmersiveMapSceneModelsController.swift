// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Public thread-safe owner of the 3D scene models supplied by app code.
/// Collects model mutations into snapshots for the renderer.
/// Thread-safe (`@unchecked Sendable`): all mutable state is serialized by
/// `lock`, so models can be updated from any thread.
public final class ImmersiveMapSceneModelsController: @unchecked Sendable {
    private let lock = NSLock()
    private var modelsById: [UInt64: ImmersiveMapSceneModel] = [:]
    private var removedIds: Set<UInt64> = []
    private var transformAnimationDurationsById: [UInt64: TimeInterval] = [:]
    private var pathAnimationsById: [UInt64: SceneModelPathAnimationRequest] = [:]
    private var cancelledPathAnimationIds: Set<UInt64> = []
    private var pathAnimationCompletionsById: [UInt64: (Bool) -> Void] = [:]
    private var version: UInt64 = 0
    private var hasChanges: Bool = false
    private var changeHandler: (() -> Void)?
    private weak var changeHandlerOwner: AnyObject?

    public init() {}

    public func add(_ model: ImmersiveMapSceneModel) {
        upsert([model])
    }

    public func add(_ models: [ImmersiveMapSceneModel]) {
        upsert(models)
    }

    /// Fully replaces the map content. Descriptor changes snap (no transform
    /// animation); coordinate changes of surviving ids animate by distance.
    public func set(_ models: [ImmersiveMapSceneModel]) {
        lock.lock()
        let newIds = Set(models.map(\.id))
        removedIds.formUnion(modelsById.keys.filter { newIds.contains($0) == false })
        modelsById = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        removedIds.subtract(newIds)
        transformAnimationDurationsById.removeAll(keepingCapacity: true)
        let droppedIds = pathAnimationCompletionsById.keys.filter { newIds.contains($0) == false }
        let droppedCompletions = droppedIds.compactMap { pathAnimationCompletionsById.removeValue(forKey: $0) }
        pathAnimationsById = pathAnimationsById.filter { newIds.contains($0.key) }
        cancelledPathAnimationIds.formIntersection(newIds)
        markChangedLocked()
        lock.unlock()

        for completion in droppedCompletions {
            completion(false)
        }
        notifyChanged()
    }

    public func upsert(_ models: [ImmersiveMapSceneModel]) {
        lock.lock()
        for model in models {
            modelsById[model.id] = model
            removedIds.remove(model.id)
        }
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    /// Moves a model along the great circle with a distance-derived duration.
    public func move(id: UInt64, to coordinate: GeoCoordinate) {
        lock.lock()
        guard var model = modelsById[id] else {
            lock.unlock()
            return
        }
        model.coordinate = coordinate
        modelsById[id] = model
        markChangedLocked()
        lock.unlock()
        notifyChanged()
    }

    public func move(id: UInt64, latitude: Double, longitude: Double) {
        move(id: id, to: GeoCoordinate(latitude: latitude, longitude: longitude))
    }

    /// Rotates a model; nil components keep their current value. The change
    /// animates as a shortest-arc quaternion slerp over `duration`.
    public func setOrientation(id: UInt64,
                               headingDegrees: Double? = nil,
                               pitchDegrees: Double? = nil,
                               rollDegrees: Double? = nil,
                               duration: TimeInterval = 0.3) {
        mutateTransform(id: id, duration: duration) { model in
            if let headingDegrees {
                model.headingDegrees = headingDegrees
            }
            if let pitchDegrees {
                model.pitchDegrees = pitchDegrees
            }
            if let rollDegrees {
                model.rollDegrees = rollDegrees
            }
        }
    }

    public func setScale(id: UInt64, _ scale: Double, duration: TimeInterval = 0.3) {
        mutateTransform(id: id, duration: duration) { model in
            model.scale = scale
        }
    }

    public func setAltitude(id: UInt64, meters: Double, duration: TimeInterval = 0.3) {
        mutateTransform(id: id, duration: duration) { model in
            model.altitudeMeters = meters
        }
    }

    /// Flies the model along `path` over `duration` seconds. While the
    /// animation runs the path owns the model's coordinate, altitude and (when
    /// the flags are set) heading and pitch; `move`, `setAltitude` and
    /// `setOrientation` for that id are recorded but not applied until the
    /// animation ends or `cancelPathAnimation(id:)` is called. `setScale` still
    /// applies.
    ///
    /// `completion` is called exactly once on the main thread: `true` when the
    /// model reached the end of the path, `false` when the animation was
    /// superseded, cancelled, or dropped because the model was removed, the map
    /// view went away, or the renderer was recreated.
    public func animate(id: UInt64,
                        along path: ImmersiveMapGeoPath,
                        duration: TimeInterval,
                        curve: ImmersiveMapPathAnimationCurve = .easeOut,
                        appliesHeading: Bool = true,
                        appliesPitch: Bool = true,
                        completion: ((Bool) -> Void)? = nil) {
        lock.lock()
        let superseded = pathAnimationCompletionsById.removeValue(forKey: id)
        guard var model = modelsById[id], let metrics = GeoPathMetrics(path: path) else {
            lock.unlock()
            superseded?(false)
            completion?(false)
            return
        }

        // The descriptor lands on the path's end state right away, so when the
        // animation finishes the model settles into what the controller already
        // holds and no later snapshot snaps it back.
        let destination = metrics.sample(atFraction: 1)
        model.coordinate = destination.coordinate
        model.altitudeMeters = destination.altitudeMeters
        if appliesHeading {
            model.headingDegrees = destination.headingDegrees
        }
        if appliesPitch {
            model.pitchDegrees = destination.pitchDegrees
        }
        modelsById[id] = model
        pathAnimationsById[id] = SceneModelPathAnimationRequest(path: path,
                                                                duration: duration,
                                                                curve: curve,
                                                                appliesHeading: appliesHeading,
                                                                appliesPitch: appliesPitch)
        cancelledPathAnimationIds.remove(id)
        if let completion {
            pathAnimationCompletionsById[id] = completion
        }
        markChangedLocked()
        lock.unlock()

        superseded?(false)
        notifyChanged()
    }

    /// Stops a running path animation, leaving the model where it is. Its
    /// completion fires with `false`.
    public func cancelPathAnimation(id: UInt64) {
        lock.lock()
        let completion = pathAnimationCompletionsById.removeValue(forKey: id)
        var changed = pathAnimationsById.removeValue(forKey: id) != nil
        if modelsById[id] != nil {
            cancelledPathAnimationIds.insert(id)
            changed = true
        }
        if changed {
            markChangedLocked()
        }
        lock.unlock()

        completion?(false)
        if changed {
            notifyChanged()
        }
    }

    public func remove(ids: [UInt64]) {
        lock.lock()
        var droppedCompletions: [(Bool) -> Void] = []
        for id in ids {
            modelsById.removeValue(forKey: id)
            removedIds.insert(id)
            transformAnimationDurationsById.removeValue(forKey: id)
            pathAnimationsById.removeValue(forKey: id)
            cancelledPathAnimationIds.remove(id)
            if let completion = pathAnimationCompletionsById.removeValue(forKey: id) {
                droppedCompletions.append(completion)
            }
        }
        markChangedLocked()
        lock.unlock()

        for completion in droppedCompletions {
            completion(false)
        }
        notifyChanged()
    }

    public func remove(id: UInt64) {
        remove(ids: [id])
    }

    public func clear() {
        lock.lock()
        removedIds.formUnion(modelsById.keys)
        modelsById.removeAll(keepingCapacity: true)
        transformAnimationDurationsById.removeAll(keepingCapacity: true)
        pathAnimationsById.removeAll(keepingCapacity: true)
        cancelledPathAnimationIds.removeAll(keepingCapacity: true)
        let droppedCompletions = Array(pathAnimationCompletionsById.values)
        pathAnimationCompletionsById.removeAll(keepingCapacity: true)
        markChangedLocked()
        lock.unlock()

        for completion in droppedCompletions {
            completion(false)
        }
        notifyChanged()
    }

    func consumeSnapshot() -> SceneModelsSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard hasChanges else { return nil }
        hasChanges = false
        let snapshot = SceneModelsSnapshot(models: Array(modelsById.values),
                                           transformAnimationDurationsById: transformAnimationDurationsById,
                                           pathAnimationsById: pathAnimationsById,
                                           cancelledPathAnimationIds: Array(cancelledPathAnimationIds),
                                           removedIds: Array(removedIds),
                                           version: version)
        removedIds.removeAll(keepingCapacity: true)
        transformAnimationDurationsById.removeAll(keepingCapacity: true)
        pathAnimationsById.removeAll(keepingCapacity: true)
        cancelledPathAnimationIds.removeAll(keepingCapacity: true)
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

    /// Fires the completions of the listed ids with `true`. Called from the
    /// render loop on the main thread when their animations reached the end.
    func finishPathAnimations(ids: [UInt64]) {
        lock.lock()
        let completions = ids.compactMap { pathAnimationCompletionsById.removeValue(forKey: $0) }
        lock.unlock()

        for completion in completions {
            completion(true)
        }
    }

    /// Drops every pending path animation and fires its completion with
    /// `false`. Called when the presentation store that owns the running
    /// animations is discarded (renderer recreation, map view teardown), which
    /// would otherwise leave app chains waiting forever.
    func cancelAllPathAnimations() {
        lock.lock()
        let completions = Array(pathAnimationCompletionsById.values)
        pathAnimationCompletionsById.removeAll(keepingCapacity: true)
        pathAnimationsById.removeAll(keepingCapacity: true)
        cancelledPathAnimationIds.removeAll(keepingCapacity: true)
        lock.unlock()

        for completion in completions {
            completion(false)
        }
    }

    func markSnapshotDirty() {
        lock.lock()
        markChangedLocked()
        lock.unlock()
    }

    private func mutateTransform(id: UInt64,
                                 duration: TimeInterval,
                                 _ mutation: (inout ImmersiveMapSceneModel) -> Void) {
        lock.lock()
        guard var model = modelsById[id] else {
            lock.unlock()
            return
        }
        mutation(&model)
        modelsById[id] = model
        transformAnimationDurationsById[id] = max(0, duration)
        markChangedLocked()
        lock.unlock()
        notifyChanged()
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

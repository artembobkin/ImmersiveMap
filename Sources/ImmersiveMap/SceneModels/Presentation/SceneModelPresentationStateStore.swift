// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// A scene model resolved for the current frame: displayed (possibly animated)
/// coordinate basis and transform values, plus the target descriptor fields
/// the renderer needs to pick and size the mesh.
struct PresentedSceneModel {
    let id: UInt64
    let source: ImmersiveMapSceneModel.Source
    let fitDiameterMeters: Double?
    /// Where the model is being drawn this frame. Mid-flight this is a point on
    /// the path, while the descriptor already holds the destination.
    let coordinate: GeoCoordinate
    let projectionBasis: GeoProjectionBasis
    let orientation: simd_quatf
    let scale: Double
    let altitudeMeters: Double
}

private struct SceneModelPositionAnimation {
    let startCoordinate: GeoCoordinate
    let targetCoordinate: GeoCoordinate
    let startTime: TimeInterval
    let duration: TimeInterval

    func coordinate(at time: TimeInterval) -> GeoCoordinate {
        guard duration > 0 else { return targetCoordinate }
        let rawProgress = (time - startTime) / duration
        let progress = SceneModelAnimationMath.easedProgress(for: rawProgress)
        return GeoGreatCircleMath.coordinate(from: startCoordinate,
                                             to: targetCoordinate,
                                             progress: progress)
    }

    func isFinished(at time: TimeInterval) -> Bool {
        time >= startTime + duration
    }
}

/// Orientation, scale, and altitude animate as one eased segment: a combined
/// `setOrientation` + `setScale` mutation lands as a single coherent motion.
private struct SceneModelTransformAnimation {
    let startOrientation: simd_quatf
    let targetOrientation: simd_quatf
    let startScale: Double
    let targetScale: Double
    let startAltitude: Double
    let targetAltitude: Double
    let startTime: TimeInterval
    let duration: TimeInterval

    func progress(at time: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return SceneModelAnimationMath.easedProgress(for: (time - startTime) / duration)
    }

    func isFinished(at time: TimeInterval) -> Bool {
        time >= startTime + duration
    }
}

/// A model flying along a path. Cached `GeoPathMetrics` keeps the per-frame
/// cost to one exact evaluation, and the model rides the drawn ribbon because
/// both resolve a fraction through the same metrics.
private struct SceneModelPathAnimation {
    let generation: UInt64
    let metrics: GeoPathMetrics
    let startTime: TimeInterval
    let duration: TimeInterval
    let curve: ImmersiveMapPathAnimationCurve
    let appliesHeading: Bool
    let appliesPitch: Bool

    /// nil when the path cannot describe a trajectory.
    init?(request: SceneModelPathAnimationRequest, startTime: TimeInterval) {
        guard let metrics = GeoPathMetrics(path: request.path) else { return nil }
        generation = request.generation
        self.metrics = metrics
        self.startTime = startTime
        duration = max(0, request.duration)
        curve = request.curve
        appliesHeading = request.appliesHeading
        appliesPitch = request.appliesPitch
    }

    func fraction(at time: TimeInterval) -> Double {
        curve.fraction(elapsed: time - startTime, duration: duration)
    }

    func isFinished(at time: TimeInterval) -> Bool {
        time >= startTime + duration
    }
}

private struct SceneModelPresentationEntry {
    var model: ImmersiveMapSceneModel
    var displayedCoordinate: GeoCoordinate
    var projectionBasis: GeoProjectionBasis
    var displayedOrientation: simd_quatf
    var displayedScale: Double
    var displayedAltitude: Double
    var positionAnimation: SceneModelPositionAnimation?
    var transformAnimation: SceneModelTransformAnimation?
    var pathAnimation: SceneModelPathAnimation?
    /// Where a path animation ended, set once on the frame it ends and drained
    /// by the store, so the app's completion fires exactly once and the
    /// controller learns where a cancelled flight stopped.
    private var pendingPathAnimationResult: SceneModelPathAnimationResult?

    init(model: ImmersiveMapSceneModel) {
        self.model = model
        displayedCoordinate = model.coordinate
        projectionBasis = GeoProjectionBasis(coordinate: model.coordinate)
        displayedOrientation = Self.orientationQuaternion(of: model)
        displayedScale = model.scale
        displayedAltitude = model.altitudeMeters
        positionAnimation = nil
        transformAnimation = nil
    }

    private static func orientationQuaternion(of model: ImmersiveMapSceneModel) -> simd_quatf {
        SceneModelAnimationMath.orientationQuaternion(headingDegrees: model.headingDegrees,
                                                      pitchDegrees: model.pitchDegrees,
                                                      rollDegrees: model.rollDegrees)
    }

    /// Changing the presented coordinate recomputes the projection basis:
    /// the only place with per-model trigonometry.
    private mutating func moveDisplayedCoordinate(to coordinate: GeoCoordinate) {
        guard coordinate.latitude != displayedCoordinate.latitude
                || coordinate.longitude != displayedCoordinate.longitude else {
            return
        }
        displayedCoordinate = coordinate
        projectionBasis = GeoProjectionBasis(coordinate: coordinate)
    }

    mutating func presentedModel(at time: TimeInterval) -> PresentedSceneModel {
        if let positionAnimation {
            moveDisplayedCoordinate(to: positionAnimation.coordinate(at: time))
            if positionAnimation.isFinished(at: time) {
                moveDisplayedCoordinate(to: positionAnimation.targetCoordinate)
                self.positionAnimation = nil
            }
        }
        if let transformAnimation {
            let progress = transformAnimation.progress(at: time)
            displayedOrientation = SceneModelAnimationMath.orientation(from: transformAnimation.startOrientation,
                                                                       to: transformAnimation.targetOrientation,
                                                                       progress: progress)
            displayedScale = SceneModelAnimationMath.scalar(from: transformAnimation.startScale,
                                                            to: transformAnimation.targetScale,
                                                            progress: progress)
            displayedAltitude = SceneModelAnimationMath.scalar(from: transformAnimation.startAltitude,
                                                               to: transformAnimation.targetAltitude,
                                                               progress: progress)
            if transformAnimation.isFinished(at: time) {
                displayedOrientation = transformAnimation.targetOrientation
                displayedScale = transformAnimation.targetScale
                displayedAltitude = transformAnimation.targetAltitude
                self.transformAnimation = nil
            }
        }

        // Last, so the path owns the fields it drives: a transform animation
        // started while flying effectively animates only the scale.
        if let pathAnimation {
            let sample = pathAnimation.metrics.sample(atFraction: pathAnimation.fraction(at: time))
            moveDisplayedCoordinate(to: sample.coordinate)
            displayedAltitude = sample.altitudeMeters
            displayedOrientation = SceneModelAnimationMath.orientationQuaternion(
                headingDegrees: pathAnimation.appliesHeading ? sample.headingDegrees : model.headingDegrees,
                pitchDegrees: pathAnimation.appliesPitch ? sample.pitchDegrees : model.pitchDegrees,
                rollDegrees: model.rollDegrees)
            if pathAnimation.isFinished(at: time) {
                self.pathAnimation = nil
                recordPathAnimationResult(generation: pathAnimation.generation, finished: true)
            }
        }

        return PresentedSceneModel(id: model.id,
                                   source: model.source,
                                   fitDiameterMeters: model.fitDiameterMeters,
                                   coordinate: displayedCoordinate,
                                   projectionBasis: projectionBasis,
                                   orientation: displayedOrientation,
                                   scale: displayedScale,
                                   altitudeMeters: displayedAltitude)
    }

    mutating func update(with model: ImmersiveMapSceneModel,
                         transformDuration: TimeInterval,
                         pathAnimationRequest: SceneModelPathAnimationRequest?,
                         cancelsPathAnimation: Bool,
                         time: TimeInterval) {
        // Which fields the path owns on this frame. A cancellation keeps that
        // ownership for the frame it lands on: the descriptor in the same
        // snapshot still names the destination, because the controller only
        // learns where the flight stopped from the result this frame emits.
        var pathOwnedFields: (appliesHeading: Bool, appliesPitch: Bool)?

        if cancelsPathAnimation, let cancelled = pathAnimation {
            _ = presentedModel(at: time)
            pathAnimation = nil
            recordPathAnimationResult(generation: cancelled.generation, finished: false)
            adoptDisplayedTransform()
            pathOwnedFields = (cancelled.appliesHeading, cancelled.appliesPitch)
        }
        if let active = pathAnimation {
            pathOwnedFields = (active.appliesHeading, active.appliesPitch)
        }

        if let pathAnimationRequest {
            // Settle first, then let the path take over: a competing move or
            // transform must not keep running underneath it.
            _ = presentedModel(at: time)
            positionAnimation = nil
            transformAnimation = nil
            pathAnimation = SceneModelPathAnimation(request: pathAnimationRequest, startTime: time)
            pendingPathAnimationResult = nil
            // The descriptor in this very snapshot IS the path's destination,
            // which is what makes the landing seamless, so it is taken as given
            // rather than frozen. Everything below still runs, so a `setScale`
            // that rode in with the request is not lost.
            pathOwnedFields = nil
        }

        // While a path owns a field, an incoming value for it is ignored rather
        // than recorded: recording it would make the entry compare the new
        // descriptor against itself once the flight ends and silently drop the
        // change forever. Everything else, scale included, applies normally.
        var model = model
        if let pathOwnedFields {
            model.coordinate = self.model.coordinate
            model.altitudeMeters = self.model.altitudeMeters
            if pathOwnedFields.appliesHeading {
                model.headingDegrees = self.model.headingDegrees
            }
            if pathOwnedFields.appliesPitch {
                model.pitchDegrees = self.model.pitchDegrees
            }
        }

        let previous = self.model
        let coordinateChanged = previous.coordinate != model.coordinate
        let transformChanged = previous.headingDegrees != model.headingDegrees
            || previous.pitchDegrees != model.pitchDegrees
            || previous.rollDegrees != model.rollDegrees
            || previous.scale != model.scale
            || previous.altitudeMeters != model.altitudeMeters
        if coordinateChanged || transformChanged {
            // Settle in-flight animations to the current time so the new
            // segment starts from what is on screen, not from stale targets.
            _ = presentedModel(at: time)
        }

        // The path drives the position itself, so an installed path suppresses
        // the glide toward the destination the descriptor now names.
        if coordinateChanged, pathAnimation == nil {
            let duration = SceneModelAnimationMath.positionAnimationDuration(from: displayedCoordinate,
                                                                             to: model.coordinate)
            positionAnimation = duration > 0
                ? SceneModelPositionAnimation(startCoordinate: displayedCoordinate,
                                              targetCoordinate: model.coordinate,
                                              startTime: time,
                                              duration: duration)
                : nil
            if duration == 0 {
                moveDisplayedCoordinate(to: model.coordinate)
            }
        }

        if transformChanged {
            let targetOrientation = Self.orientationQuaternion(of: model)
            if transformDuration > 0 {
                transformAnimation = SceneModelTransformAnimation(startOrientation: displayedOrientation,
                                                                  targetOrientation: targetOrientation,
                                                                  startScale: displayedScale,
                                                                  targetScale: model.scale,
                                                                  startAltitude: displayedAltitude,
                                                                  targetAltitude: model.altitudeMeters,
                                                                  startTime: time,
                                                                  duration: transformDuration)
            } else {
                transformAnimation = nil
                displayedOrientation = targetOrientation
                displayedScale = model.scale
                displayedAltitude = model.altitudeMeters
            }
        }

        self.model = model
    }

    func hasActiveAnimations(at time: TimeInterval) -> Bool {
        positionAnimation != nil || transformAnimation != nil || pathAnimation != nil
    }

    mutating func takePathAnimationResult() -> SceneModelPathAnimationResult? {
        defer { pendingPathAnimationResult = nil }
        return pendingPathAnimationResult
    }

    /// Makes the descriptor agree with what is on screen, so a later snapshot
    /// carrying the same descriptor starts no animation.
    private mutating func adoptDisplayedTransform() {
        model.coordinate = displayedCoordinate
        model.altitudeMeters = displayedAltitude
        let angles = SceneModelAnimationMath.orientationAngles(of: displayedOrientation)
        model.headingDegrees = angles.headingDegrees
        model.pitchDegrees = angles.pitchDegrees
        model.rollDegrees = angles.rollDegrees
    }

    private mutating func recordPathAnimationResult(generation: UInt64, finished: Bool) {
        let angles = SceneModelAnimationMath.orientationAngles(of: displayedOrientation)
        pendingPathAnimationResult = SceneModelPathAnimationResult(id: model.id,
                                                                   generation: generation,
                                                                   finished: finished,
                                                                   coordinate: displayedCoordinate,
                                                                   altitudeMeters: displayedAltitude,
                                                                   headingDegrees: angles.headingDegrees,
                                                                   pitchDegrees: angles.pitchDegrees)
    }
}

/// Scene model presentation store: keeps entries sorted by ascending id plus a
/// cached presented list. Per-frame cost is proportional to the number of
/// ANIMATING models, not the total count: static models between mutations cost
/// only returning the cached array.
final class SceneModelPresentationStateStore {
    private var entries: [SceneModelPresentationEntry] = []
    private var presentedCache: [PresentedSceneModel] = []
    private var animatingIndices: [Int] = []
    private var pathAnimationResults: [SceneModelPathAnimationResult] = []
    private(set) var hasActiveAnimations: Bool = false

    var isEmpty: Bool {
        entries.isEmpty
    }

    init() {}

    func apply(snapshot: SceneModelsSnapshot, time: TimeInterval) {
        var previousEntriesByID = Dictionary<UInt64, SceneModelPresentationEntry>(minimumCapacity: entries.count)
        for entry in entries {
            previousEntriesByID[entry.model.id] = entry
        }

        let cancelledPathAnimationIds = Set(snapshot.cancelledPathAnimationIds)
        let sortedModels = snapshot.models.sorted { $0.id < $1.id }
        entries = sortedModels.map { model in
            if var existing = previousEntriesByID[model.id] {
                existing.update(with: model,
                                transformDuration: snapshot.transformAnimationDurationsById[model.id] ?? 0,
                                pathAnimationRequest: snapshot.pathAnimationsById[model.id],
                                cancelsPathAnimation: cancelledPathAnimationIds.contains(model.id),
                                time: time)
                return existing
            }
            var entry = SceneModelPresentationEntry(model: model)
            if let request = snapshot.pathAnimationsById[model.id] {
                entry.update(with: model,
                             transformDuration: 0,
                             pathAnimationRequest: request,
                             cancelsPathAnimation: false,
                             time: time)
            }
            return entry
        }

        presentedCache = entries.indices.map { index in
            let presented = entries[index].presentedModel(at: time)
            collectPathAnimationResult(at: index)
            return presented
        }
        animatingIndices = entries.indices.filter { entries[$0].hasActiveAnimations(at: time) }
        hasActiveAnimations = animatingIndices.isEmpty == false
    }

    /// Returns the presented list sorted by ascending id. The caller must not
    /// retain the array across frames: the cache is updated in place, and
    /// retaining it would trigger a COW copy of all models.
    func presentedEntries(at time: TimeInterval) -> [PresentedSceneModel] {
        guard animatingIndices.isEmpty == false else {
            hasActiveAnimations = false
            return presentedCache
        }

        var stillAnimating: [Int] = []
        stillAnimating.reserveCapacity(animatingIndices.count)
        for index in animatingIndices {
            presentedCache[index] = entries[index].presentedModel(at: time)
            collectPathAnimationResult(at: index)
            if entries[index].hasActiveAnimations(at: time) {
                stillAnimating.append(index)
            }
        }
        animatingIndices = stillAnimating
        hasActiveAnimations = stillAnimating.isEmpty == false
        return presentedCache
    }

    /// Drains the path animations that ended since the last call.
    func consumePathAnimationResults() -> [SceneModelPathAnimationResult] {
        defer { pathAnimationResults.removeAll(keepingCapacity: true) }
        return pathAnimationResults
    }

    private func collectPathAnimationResult(at index: Int) {
        guard let result = entries[index].takePathAnimationResult() else { return }
        pathAnimationResults.append(result)
    }
}

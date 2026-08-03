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
        return SceneModelAnimationMath.coordinate(from: startCoordinate,
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

private struct SceneModelPresentationEntry {
    var model: ImmersiveMapSceneModel
    var displayedCoordinate: GeoCoordinate
    var projectionBasis: GeoProjectionBasis
    var displayedOrientation: simd_quatf
    var displayedScale: Double
    var displayedAltitude: Double
    var positionAnimation: SceneModelPositionAnimation?
    var transformAnimation: SceneModelTransformAnimation?

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

        return PresentedSceneModel(id: model.id,
                                   source: model.source,
                                   fitDiameterMeters: model.fitDiameterMeters,
                                   projectionBasis: projectionBasis,
                                   orientation: displayedOrientation,
                                   scale: displayedScale,
                                   altitudeMeters: displayedAltitude)
    }

    mutating func update(with model: ImmersiveMapSceneModel,
                         transformDuration: TimeInterval,
                         time: TimeInterval) {
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

        if coordinateChanged {
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
        positionAnimation != nil || transformAnimation != nil
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

        let sortedModels = snapshot.models.sorted { $0.id < $1.id }
        entries = sortedModels.map { model in
            if var existing = previousEntriesByID[model.id] {
                existing.update(with: model,
                                transformDuration: snapshot.transformAnimationDurationsById[model.id] ?? 0,
                                time: time)
                return existing
            }
            return SceneModelPresentationEntry(model: model)
        }

        presentedCache = entries.indices.map { entries[$0].presentedModel(at: time) }
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
            if entries[index].hasActiveAnimations(at: time) {
                stillAnimating.append(index)
            }
        }
        animatingIndices = stillAnimating
        hasActiveAnimations = stillAnimating.isEmpty == false
        return presentedCache
    }
}

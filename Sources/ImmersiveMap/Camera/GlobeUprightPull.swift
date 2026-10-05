// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// How far from upright (north up, looking straight down) the globe's camera
/// may rest at a zoom. Unlike `CameraConstraints` this is not a wall: the
/// camera may be outside it, and `GlobeUprightPull` draws it back.
struct GlobeUprightWindow: Equatable {
    let maximumAbsoluteBearing: Float
    let maximumPitch: Float

    func clampedBearing(_ bearing: Float) -> Float {
        min(max(bearing, -maximumAbsoluteBearing), maximumAbsoluteBearing)
    }
}

/// The pull that keeps a zoomed-out globe upright
/// (`CameraSettings.GlobeUprightPull`): the window it holds the camera to,
/// and the eased step toward that window.
enum GlobeUprightPull {
    struct Step: Equatable {
        let bearing: Float
        let pitch: Float
        /// Whether either angle is still outside the window.
        let isPulling: Bool
    }

    /// An angle this close to the window, in radians, lands on it.
    static let snapThreshold: Float = 0.0003

    /// The window at a zoom, nil where nothing is held: with the pull off, on
    /// the flat map, and from the upper bound of the zoom range on. It closes
    /// linearly from the camera's own limits at the upper bound to north up
    /// and the pitch floor at the lower one.
    static func window(zoom: Double,
                       settings: ImmersiveMapSettings.CameraSettings.GlobeUprightPull?,
                       renderSurfaceMode: ViewMode,
                       constraints: CameraConstraints) -> GlobeUprightWindow? {
        guard let settings,
              renderSurfaceMode == .spherical,
              zoom < settings.zoomRange.upperBound else {
            return nil
        }

        let span = settings.zoomRange.upperBound - settings.zoomRange.lowerBound
        let progress = span > Double.leastNonzeroMagnitude
            ? Float(min(max((zoom - settings.zoomRange.lowerBound) / span, 0), 1))
            : 0
        let bearingCeiling = min(max(constraints.bearing.maximumAbsoluteBearing ?? .pi, 0), .pi)
        let pitchFloor = constraints.pitch.clampedMinimumPitch
        let pitchCeiling = constraints.pitch.clampedMaximumPitch
        return GlobeUprightWindow(maximumAbsoluteBearing: bearingCeiling * progress,
                                  maximumPitch: pitchFloor + (pitchCeiling - pitchFloor) * progress)
    }

    /// One frame of the pull: the part of each angle outside the window
    /// halves every `halfLife` seconds. An angle inside the window is
    /// returned as it came.
    static func step(bearing: Float,
                     pitch: Float,
                     window: GlobeUprightWindow,
                     deltaTime: Double,
                     halfLife: Double) -> Step {
        let remaining = halfLife > 0 && halfLife.isFinite
            ? Float(exp(-log(2.0) * max(deltaTime, 0) / halfLife))
            : 0

        let normalizedBearing = CameraBearingConstraintResolver.normalized(bearing)
        let bearingEdge = window.clampedBearing(normalizedBearing)
        let bearingStep = pulled(normalizedBearing, toward: bearingEdge, remaining: remaining)
        let pitchEdge = min(pitch, window.maximumPitch)
        let pitchStep = pulled(pitch, toward: pitchEdge, remaining: remaining)

        return Step(bearing: normalizedBearing == bearingEdge ? bearing : bearingStep.value,
                    pitch: pitchStep.value,
                    isPulling: bearingStep.isOutside || pitchStep.isOutside)
    }

    private static func pulled(_ value: Float,
                               toward edge: Float,
                               remaining: Float) -> (value: Float, isOutside: Bool) {
        let excess = (value - edge) * remaining
        guard abs(excess) > snapThreshold else {
            return (edge, false)
        }
        return (edge + excess, true)
    }
}

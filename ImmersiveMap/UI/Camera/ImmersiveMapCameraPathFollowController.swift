// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import QuartzCore
import simd

/// Drives the camera along an `ImmersiveMapGeoPath`: the traversal state, the
/// per-frame catch-up toward the point of the path, and the completion.
///
/// The camera resolves its own point of the path from the shared
/// `GeoPathMetrics` and `ImmersiveMapPathAnimationCurve`, the same pair a scene
/// model animation uses, so a model and the camera started together travel in
/// step without a channel between the render side and here.
@MainActor
final class ImmersiveMapCameraPathFollowController {
    private struct Traversal {
        let metrics: GeoPathMetrics
        let curve: ImmersiveMapPathAnimationCurve
        let options: ImmersiveMapCameraFollowOptions
        let startTime: CFTimeInterval
        let duration: TimeInterval
    }

    private let cameraRuntime: ImmersiveMapCameraRuntime
    private let interactionRuntime: ImmersiveMapInteractionRuntime
    private let renderRuntime: ImmersiveMapRenderRuntime
    private weak var cameraAnimationRuntime: ImmersiveMapCameraAnimationRuntime?
    private var traversal: Traversal?
    private var lastTickTime: CFTimeInterval = 0
    private var completion: ((Bool) -> Void)?

    init(cameraRuntime: ImmersiveMapCameraRuntime,
         interactionRuntime: ImmersiveMapInteractionRuntime,
         cameraAnimationRuntime: ImmersiveMapCameraAnimationRuntime,
         renderRuntime: ImmersiveMapRenderRuntime) {
        self.cameraRuntime = cameraRuntime
        self.interactionRuntime = interactionRuntime
        self.cameraAnimationRuntime = cameraAnimationRuntime
        self.renderRuntime = renderRuntime
    }

    var isActive: Bool {
        traversal != nil
    }

    func start(path: ImmersiveMapGeoPath,
               duration: TimeInterval,
               curve: ImmersiveMapPathAnimationCurve,
               options: ImmersiveMapCameraFollowOptions,
               completion: ((Bool) -> Void)?,
               currentTime: CFTimeInterval) {
        guard cameraRuntime.currentCameraState() != nil, let metrics = GeoPathMetrics(path: path) else {
            completion?(false)
            return
        }

        // The superseded completion is taken before anything can fire it and
        // called last: a `follow` or `fly` issued from inside it must act on
        // settled state instead of being overwritten by this install.
        let superseded = self.completion
        self.completion = nil
        traversal = nil

        // Cancels a flight and the inertia, resolving their completions before
        // this traversal takes the camera.
        cameraAnimationRuntime?.cancelAnimations()

        guard duration > 0 else {
            applyCameraState(sample: metrics.sample(atFraction: 1), catchUpFraction: 1, options: options)
            superseded?(false)
            completion?(true)
            return
        }

        traversal = Traversal(metrics: metrics,
                              curve: curve,
                              options: options,
                              startTime: currentTime,
                              duration: duration)
        lastTickTime = currentTime
        self.completion = completion
        cameraAnimationRuntime?.refreshRenderingState()
        renderRuntime.requestFrame()
        superseded?(false)
    }

    func cancel(notifyCompletion: Bool = true) {
        guard traversal != nil || completion != nil else {
            cameraAnimationRuntime?.refreshRenderingState()
            return
        }

        traversal = nil
        if notifyCompletion {
            finish(success: false)
        } else {
            completion = nil
            cameraAnimationRuntime?.refreshRenderingState()
        }
    }

    func advanceIfNeeded(currentTime: CFTimeInterval) {
        guard let traversal else { return }

        // The user taking the camera wins, exactly as it does over a flight.
        guard interactionRuntime.hasActiveUserInteraction == false,
              cameraRuntime.currentCameraState() != nil else {
            cancel()
            return
        }

        let elapsed = currentTime - traversal.startTime
        let fraction = traversal.curve.fraction(elapsed: elapsed, duration: traversal.duration)
        let isFinalStep = elapsed >= traversal.duration
        let catchUpFraction = CameraPathFollowMath.catchUpFraction(
            deltaTime: currentTime - lastTickTime,
            halfLife: traversal.options.smoothingHalfLife,
            capsDeltaTime: isFinalStep == false)
        lastTickTime = currentTime

        applyCameraState(sample: traversal.metrics.sample(atFraction: fraction),
                         catchUpFraction: catchUpFraction,
                         options: traversal.options)

        // No frame request here: `setCameraState` already invalidates, and the
        // `.cameraAnimation` activity keeps the display link running.
        guard isFinalStep else {
            cameraAnimationRuntime?.refreshRenderingState()
            return
        }

        // No snap onto the endpoint: with smoothing the camera trails the point
        // by design, and jumping the residual gap would undo the smoothing in
        // one frame. `smoothingHalfLife: 0` lands exactly on it.
        self.traversal = nil
        finish(success: true)
    }

    func reset() {
        traversal = nil
        completion = nil
        cameraAnimationRuntime?.refreshRenderingState()
    }

    private func applyCameraState(sample: GeoPathSample,
                                  catchUpFraction: Double,
                                  options: ImmersiveMapCameraFollowOptions) {
        guard let currentState = cameraRuntime.currentCameraState() else { return }

        let targetCenter = CameraPathFollowMath.centerWorldMercator(of: sample.coordinate)
        let center = CameraPathFollowMath.steppedCenter(current: currentState.centerWorldMercator,
                                                        target: targetCenter,
                                                        catchUpFraction: catchUpFraction)
        let zoom = options.zoom.map {
            CameraPathFollowMath.steppedScalar(current: currentState.zoom,
                                               target: $0,
                                               catchUpFraction: catchUpFraction)
        } ?? currentState.zoom
        let pitch = options.pitch.map {
            Float(CameraPathFollowMath.steppedScalar(current: Double(currentState.pitch),
                                                     target: Double($0),
                                                     catchUpFraction: catchUpFraction))
        } ?? currentState.pitch

        let bearing: Float
        switch options.bearing {
        case .unchanged:
            bearing = currentState.bearing
        case .fixed(let value):
            bearing = Self.steppedBearing(current: currentState.bearing,
                                          target: value,
                                          catchUpFraction: catchUpFraction)
        case .course:
            bearing = Self.steppedBearing(current: currentState.bearing,
                                          target: Self.bearingPuttingCourseUpTheScreen(sample.headingDegrees),
                                          catchUpFraction: catchUpFraction)
        }

        cameraRuntime.setCameraState(ImmersiveMapCameraState(centerWorldMercator: center,
                                                             zoom: zoom,
                                                             bearing: bearing,
                                                             pitch: pitch))
    }

    /// The camera's bearing is the NEGATION of the compass direction that ends
    /// up pointing up the screen: the pose resolver rotates the up vector by
    /// `bearing` about +Z in an (east, north) frame, so screen-up on the ground
    /// is `(-sin bearing, cos bearing)`. Putting a course up the screen
    /// therefore means steering to minus that course.
    static func bearingPuttingCourseUpTheScreen(_ headingDegrees: Double) -> Float {
        Float(-headingDegrees * .pi / 180.0)
    }

    /// Bearing is cyclic, so the gap is closed along the shortest arc. Reading
    /// `current` back from the camera every frame means a bearing the globe
    /// constraints clamped is absorbed instead of fought.
    private static func steppedBearing(current: Float, target: Float, catchUpFraction: Double) -> Float {
        let delta = CameraBearingFollowMath.shortestDelta(current: current, target: target)
        return current + delta * Float(min(max(catchUpFraction, 0), 1))
    }

    private func finish(success: Bool) {
        let completion = completion
        self.completion = nil
        cameraAnimationRuntime?.refreshRenderingState()
        completion?(success)
    }
}

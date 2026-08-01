// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Deterministic re-implementation of the camera tour for offline export.
///
/// `ImmersiveMapCameraTourController` chains real-time flights over the wall
/// clock; this driver replays the same shot semantics — establish jump, one
/// flight per shot, exact-target snap on arrival, hold after each shot — as a
/// pure function of export-timeline time, stepped frame by frame.
///
/// Timing is precomputable because every flight lands snapped exactly on its
/// target: segment N always starts from shot N-1's position (or the establish/
/// start position), so degenerate shots (no meaningful delta or non-positive
/// duration) statically collapse to 0 s, mirroring the live controller's
/// immediate completion.
@MainActor
final class TourVideoTimelineDriver {
    struct Plan: Equatable {
        let totalDuration: TimeInterval
        /// Frames to capture at the given rate, inclusive of both endpoints
        /// (frame 0 at t = 0, last frame at t ≥ totalDuration).
        let frameCount: Int
    }

    private struct Segment {
        let shot: ImmersiveMapCameraTourShot
        let startTime: TimeInterval
        let flightDuration: TimeInterval
        let holdDuration: TimeInterval

        var flightEndTime: TimeInterval { startTime + flightDuration }
        var endTime: TimeInterval { startTime + flightDuration + holdDuration }
    }

    private let segments: [Segment]
    private let settings: ImmersiveMapSettings
    private let renderCamera: FrameCameraStateResolver
    private let presentationStateResolver: MapPresentationStateController
    private let animator = CameraFlightAnimator()
    private var currentSegmentIndex = 0
    /// Index of the segment whose flight is currently loaded into the animator.
    private var flyingSegmentIndex = -1
    /// Index of the last segment snapped to its exact target (idempotence guard).
    private var snappedSegmentIndex = -1

    /// `initialPosition` is where the tour starts: the establish position when
    /// one was given, otherwise the live map's current camera position.
    init(shots: [ImmersiveMapCameraTourShot],
         initialPosition: ImmersiveMapCameraPosition,
         settings: ImmersiveMapSettings,
         renderCamera: FrameCameraStateResolver,
         presentationStateResolver: MapPresentationStateController) {
        self.segments = Self.makeSegments(shots: shots,
                                          initialPosition: initialPosition,
                                          settings: settings)
        self.settings = settings
        self.renderCamera = renderCamera
        self.presentationStateResolver = presentationStateResolver
        // Mirrors the live tour's establish semantics: an instant jump before
        // the first shot. Also overrides the resolver's built-in default position.
        setCameraPosition(initialPosition)
    }

    var isFinished: Bool {
        currentSegmentIndex >= segments.count
    }

    static func makePlan(shots: [ImmersiveMapCameraTourShot],
                         initialPosition: ImmersiveMapCameraPosition,
                         settings: ImmersiveMapSettings,
                         framesPerSecond: Int) -> Plan {
        let segments = makeSegments(shots: shots,
                                    initialPosition: initialPosition,
                                    settings: settings)
        let totalDuration = segments.last?.endTime ?? 0
        let frameCount = max(1, Int((totalDuration * Double(framesPerSecond)).rounded(.up)) + 1)
        return Plan(totalDuration: totalDuration, frameCount: frameCount)
    }

    /// Applies the camera state for export-timeline time `time`. Times must be
    /// fed monotonically; segments fully behind `time` land snapped on their
    /// targets even when the frame step jumped past them.
    func advance(to time: TimeInterval) {
        while currentSegmentIndex < segments.count {
            let segment = segments[currentSegmentIndex]
            if time >= segment.endTime {
                snapToTarget(of: segment)
                currentSegmentIndex += 1
                continue
            }
            if time < segment.flightEndTime, segment.flightDuration > 0 {
                advanceFlight(of: segment, at: time)
            } else {
                // Hold part of the shot: parked exactly on the target.
                snapToTarget(of: segment)
            }
            return
        }
    }

    private func advanceFlight(of segment: Segment, at time: TimeInterval) {
        if flyingSegmentIndex != currentSegmentIndex {
            let startState = renderCamera.currentCameraState()
            let targetState = ImmersiveMapCameraState(cameraPosition: segment.shot.position,
                                                      cameraSettings: settings.camera)
            let routeStyle = resolveRouteStyle(segment.shot.options.routeStyle,
                                               startState: startState,
                                               targetState: targetState)
            // Anchored at the segment's scheduled start, not at first-render
            // time, so progress is a pure function of the export timeline.
            let didStart = animator.start(from: startState,
                                          to: targetState,
                                          duration: segment.flightDuration,
                                          routeStyle: routeStyle,
                                          altitudeStyle: segment.shot.options.altitudeStyle,
                                          currentTime: segment.startTime)
            flyingSegmentIndex = currentSegmentIndex
            guard didStart else {
                // The clamped runtime start state can degenerate the delta even
                // when the static plan saw one; land immediately, like live.
                snapToTarget(of: segment)
                return
            }
        }

        guard let step = animator.advance(currentTime: time) else {
            return
        }
        setCameraState(step.cameraState)
        if step.didFinish {
            snapToTarget(of: segment)
        }
    }

    private func snapToTarget(of segment: Segment) {
        guard snappedSegmentIndex < currentSegmentIndex else {
            return
        }
        snappedSegmentIndex = currentSegmentIndex
        animator.cancel()
        setCameraPosition(segment.shot.position)
    }

    /// Mirrors `ImmersiveMapCameraFlightController.resolveRouteStyle`.
    private func resolveRouteStyle(_ routeStyle: CameraFlightRouteStyle,
                                   startState: ImmersiveMapCameraState,
                                   targetState: ImmersiveMapCameraState) -> CameraFlightAnimator.ResolvedRouteStyle {
        switch routeStyle {
        case .mercatorShortestPath:
            return .mercatorShortestPath
        case .greatCircle:
            return .greatCircle
        case .automatic:
            let automaticTransitionStartZoom = settings.presentation.automaticTransitionStartZoom
            let useGreatCircle = presentationStateResolver.isSphericalSurfaceActive(cameraState: startState)
                || min(startState.zoom, targetState.zoom) < automaticTransitionStartZoom
            return useGreatCircle ? .greatCircle : .mercatorShortestPath
        }
    }

    /// Mirrors `ImmersiveMapCameraRuntime.setCameraState`: every state
    /// application is followed by the presentation-derived constraint clamp.
    private func setCameraState(_ cameraState: ImmersiveMapCameraState) {
        renderCamera.setCameraState(cameraState)
        applyCurrentConstraints()
    }

    private func setCameraPosition(_ cameraPosition: ImmersiveMapCameraPosition) {
        renderCamera.setCameraPosition(cameraPosition)
        applyCurrentConstraints()
    }

    private func applyCurrentConstraints() {
        let constraints = presentationStateResolver.cameraConstraints(cameraState: renderCamera.currentCameraState())
        renderCamera.applyConstraints(constraints)
    }

    private static func makeSegments(shots: [ImmersiveMapCameraTourShot],
                                     initialPosition: ImmersiveMapCameraPosition,
                                     settings: ImmersiveMapSettings) -> [Segment] {
        var previousPosition = initialPosition
        var cursor: TimeInterval = 0
        var segments: [Segment] = []
        segments.reserveCapacity(shots.count)
        for shot in shots {
            let startState = ImmersiveMapCameraState(cameraPosition: previousPosition,
                                                     cameraSettings: settings.camera)
            let targetState = ImmersiveMapCameraState(cameraPosition: shot.position,
                                                      cameraSettings: settings.camera)
            let sanitizedDuration = shot.options.duration.isFinite
                ? shot.options.duration
                : CameraFlightMath.minimumDuration
            let hasDelta = CameraFlightMath.hasMeaningfulDelta(from: startState, to: targetState)
            let flightDuration = (hasDelta && sanitizedDuration > 0) ? sanitizedDuration : 0
            let holdDuration = max(0, shot.holdAfter)
            segments.append(Segment(shot: shot,
                                    startTime: cursor,
                                    flightDuration: flightDuration,
                                    holdDuration: holdDuration))
            cursor += flightDuration + holdDuration
            previousPosition = shot.position
        }
        return segments
    }
}

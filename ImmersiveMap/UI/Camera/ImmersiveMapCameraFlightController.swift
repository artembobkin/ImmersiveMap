// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import Foundation
import QuartzCore

/// Управляет state machine перелета камеры: запуском `CameraFlightAnimator`,
/// target position, completion callback и пошаговым применением animated camera state.
final class ImmersiveMapCameraFlightController {
    private let cameraRuntime: ImmersiveMapCameraRuntime
    private let interactionRuntime: ImmersiveMapInteractionRuntime
    private let renderRuntime: ImmersiveMapRenderRuntime
    private weak var cameraAnimationRuntime: ImmersiveMapCameraAnimationRuntime?
    private let animator = CameraFlightAnimator()
    private var targetPosition: ImmersiveMapCameraPosition?
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
        animator.isActive
    }

    func start(to cameraPosition: ImmersiveMapCameraPosition,
               options: CameraFlightOptions,
               completion: ((Bool) -> Void)?,
               currentTime: CFTimeInterval) {
        guard let startState = cameraRuntime.currentCameraState() else {
            completion?(false)
            return
        }

        cameraAnimationRuntime?.cancelAnimations()
        let targetState = ImmersiveMapCameraState(cameraPosition: cameraPosition,
                                                  cameraSettings: cameraRuntime.currentSettings.camera)
        if CameraFlightMath.hasMeaningfulDelta(from: startState, to: targetState) == false || options.duration <= 0 {
            applyFinalCameraPosition(cameraPosition)
            completion?(true)
            return
        }

        let resolvedRouteStyle = resolveRouteStyle(options.routeStyle,
                                                   startState: startState,
                                                   targetState: targetState)
        let didStart = animator.start(from: startState,
                                      to: targetState,
                                      duration: options.duration,
                                      routeStyle: resolvedRouteStyle,
                                      altitudeStyle: options.altitudeStyle,
                                      currentTime: currentTime)
        guard didStart else {
            applyFinalCameraPosition(cameraPosition)
            completion?(true)
            return
        }

        targetPosition = cameraPosition
        self.completion = completion
        refreshCameraAnimationRenderingState()
        renderRuntime.requestFrame()
    }

    func cancel(notifyCompletion: Bool = true) {
        guard animator.isActive || completion != nil else {
            refreshCameraAnimationRenderingState()
            return
        }

        animator.cancel()
        if notifyCompletion {
            finish(success: false)
        } else {
            completion = nil
            targetPosition = nil
            refreshCameraAnimationRenderingState()
        }
    }

    func advanceIfNeeded(currentTime: CFTimeInterval) {
        guard animator.isActive else {
            refreshCameraAnimationRenderingState()
            return
        }

        guard interactionRuntime.hasActiveUserInteraction == false,
              cameraRuntime.currentCameraState() != nil else {
            cancel()
            return
        }

        guard let step = animator.advance(currentTime: currentTime) else {
            refreshCameraAnimationRenderingState()
            return
        }

        cameraRuntime.setCameraState(step.cameraState)

        guard step.didFinish else {
            refreshCameraAnimationRenderingState()
            return
        }

        if let targetPosition {
            applyFinalCameraPosition(targetPosition)
        }
        finish(success: true)
    }

    func reset() {
        animator.cancel()
        completion = nil
        targetPosition = nil
        refreshCameraAnimationRenderingState()
    }

    private func resolveRouteStyle(_ routeStyle: CameraFlightRouteStyle,
                                   startState: ImmersiveMapCameraState,
                                   targetState: ImmersiveMapCameraState) -> CameraFlightAnimator.ResolvedRouteStyle {
        switch routeStyle {
        case .mercatorShortestPath:
            return .mercatorShortestPath
        case .greatCircle:
            return .greatCircle
        case .automatic:
            let automaticTransitionStartZoom = cameraRuntime.currentSettings.presentation.automaticTransitionStartZoom
            let useGreatCircle = cameraRuntime.isSphericalRenderSurfaceActive()
                || min(startState.zoom, targetState.zoom) < automaticTransitionStartZoom
            return useGreatCircle ? .greatCircle : .mercatorShortestPath
        }
    }

    private func applyFinalCameraPosition(_ cameraPosition: ImmersiveMapCameraPosition) {
        cameraRuntime.setCameraPosition(cameraPosition)
    }

    private func finish(success: Bool) {
        let completion = completion
        self.completion = nil
        targetPosition = nil
        refreshCameraAnimationRenderingState()
        completion?(success)
    }

    private func refreshCameraAnimationRenderingState() {
        cameraAnimationRuntime?.refreshRenderingState()
    }
}

#endif

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Чистый механизм интерполяции для camera flights.
/// Хранит один активный flight и выдает шаги состояния камеры для заданного display-link time.
final class CameraFlightAnimator {
    enum ResolvedRouteStyle {
        case mercatorShortestPath
        case greatCircle
    }

    struct Step {
        let cameraState: ImmersiveMapCameraState
        let didFinish: Bool
    }

    private struct Flight {
        let startState: ImmersiveMapCameraState
        let targetState: ImmersiveMapCameraState
        let duration: TimeInterval
        let routeStyle: ResolvedRouteStyle
        let altitudeStyle: CameraFlightAltitudeStyle
        let startTime: CFTimeInterval
    }

    private var flight: Flight?

    var isActive: Bool {
        flight != nil
    }

    @discardableResult
    func start(from startState: ImmersiveMapCameraState,
               to targetState: ImmersiveMapCameraState,
               duration: TimeInterval,
               routeStyle: ResolvedRouteStyle,
               altitudeStyle: CameraFlightAltitudeStyle,
               currentTime: CFTimeInterval) -> Bool {
        let sanitizedDuration = max(CameraFlightMath.minimumDuration, duration.isFinite ? duration : 0)
        guard CameraFlightMath.hasMeaningfulDelta(from: startState, to: targetState) else {
            cancel()
            return false
        }

        flight = Flight(startState: startState,
                        targetState: targetState,
                        duration: sanitizedDuration,
                        routeStyle: routeStyle,
                        altitudeStyle: altitudeStyle,
                        startTime: currentTime)
        return true
    }

    func advance(currentTime: CFTimeInterval) -> Step? {
        guard let flight else {
            return nil
        }

        let rawProgress = flight.duration > 0 ? (currentTime - flight.startTime) / flight.duration : 1
        let clampedProgress = min(max(rawProgress, 0), 1)
        let easedProgress = CameraFlightMath.easeInOutCubic(clampedProgress)
        let centerWorldMercator: SIMD2<Double>
        switch flight.routeStyle {
        case .mercatorShortestPath:
            centerWorldMercator = CameraFlightMath.mercatorCenter(from: flight.startState.centerWorldMercator,
                                                                  to: flight.targetState.centerWorldMercator,
                                                                  progress: easedProgress)
        case .greatCircle:
            centerWorldMercator = CameraFlightMath.greatCircleCenter(from: flight.startState.centerWorldMercator,
                                                                     to: flight.targetState.centerWorldMercator,
                                                                     progress: easedProgress)
            ?? CameraFlightMath.mercatorCenter(from: flight.startState.centerWorldMercator,
                                               to: flight.targetState.centerWorldMercator,
                                               progress: easedProgress)
        }

        let zoom = CameraFlightMath.interpolatedZoom(from: flight.startState,
                                                     to: flight.targetState,
                                                     rawProgress: clampedProgress,
                                                     easedProgress: easedProgress,
                                                     altitudeStyle: flight.altitudeStyle)
        let bearing = CameraFlightMath.interpolateBearing(from: flight.startState.bearing,
                                                          to: flight.targetState.bearing,
                                                          progress: easedProgress)
        let pitch = flight.startState.pitch + (flight.targetState.pitch - flight.startState.pitch) * Float(easedProgress)
        let nextState = ImmersiveMapCameraState(centerWorldMercator: centerWorldMercator,
                                                zoom: zoom,
                                                bearing: bearing,
                                                pitch: pitch)
        let didFinish = clampedProgress >= 1
        if didFinish {
            self.flight = nil
        }

        return Step(cameraState: nextState,
                    didFinish: didFinish)
    }

    func cancel() {
        flight = nil
    }
}

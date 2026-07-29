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
        /// nil означает прямую интерполяцию зума (`.direct` или вырожденный маршрут).
        let overviewProfile: CameraFlightMath.OverviewFlightProfile?
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
                        overviewProfile: Self.makeOverviewProfile(from: startState,
                                                                  to: targetState,
                                                                  routeStyle: routeStyle,
                                                                  altitudeStyle: altitudeStyle),
                        startTime: currentTime)
        return true
    }

    private static func makeOverviewProfile(from startState: ImmersiveMapCameraState,
                                            to targetState: ImmersiveMapCameraState,
                                            routeStyle: ResolvedRouteStyle,
                                            altitudeStyle: CameraFlightAltitudeStyle)
        -> CameraFlightMath.OverviewFlightProfile? {
        guard altitudeStyle == .overviewFirst else {
            return nil
        }

        let routeDistance: Double
        switch routeStyle {
        case .mercatorShortestPath:
            routeDistance = CameraFlightMath.mercatorRouteDistance(from: startState.centerWorldMercator,
                                                                   to: targetState.centerWorldMercator)
        case .greatCircle:
            routeDistance = CameraFlightMath.greatCircleRouteDistance(from: startState.centerWorldMercator,
                                                                      to: targetState.centerWorldMercator)
        }
        return CameraFlightMath.OverviewFlightProfile.make(startZoom: startState.zoom,
                                                           targetZoom: targetState.zoom,
                                                           normalizedWorldDistance: routeDistance)
    }

    func advance(currentTime: CFTimeInterval) -> Step? {
        guard let flight else {
            return nil
        }

        let rawProgress = flight.duration > 0 ? (currentTime - flight.startTime) / flight.duration : 1
        let clampedProgress = min(max(rawProgress, 0), 1)
        let easedProgress = CameraFlightMath.easeInOutCubic(clampedProgress)
        // Профиль связывает пан и зум: у земли центр почти стоит, основную
        // дистанцию камера проходит на апексе, поэтому пан идёт по panProgress.
        let overviewSample = flight.overviewProfile?.sample(atProgress: easedProgress)
        let panProgress = overviewSample?.panProgress ?? easedProgress
        let centerWorldMercator: SIMD2<Double>
        switch flight.routeStyle {
        case .mercatorShortestPath:
            centerWorldMercator = CameraFlightMath.mercatorCenter(from: flight.startState.centerWorldMercator,
                                                                  to: flight.targetState.centerWorldMercator,
                                                                  progress: panProgress)
        case .greatCircle:
            centerWorldMercator = CameraFlightMath.greatCircleCenter(from: flight.startState.centerWorldMercator,
                                                                     to: flight.targetState.centerWorldMercator,
                                                                     progress: panProgress)
            ?? CameraFlightMath.mercatorCenter(from: flight.startState.centerWorldMercator,
                                               to: flight.targetState.centerWorldMercator,
                                               progress: panProgress)
        }

        let zoom = overviewSample?.zoom
            ?? flight.startState.zoom + (flight.targetState.zoom - flight.startState.zoom) * easedProgress
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

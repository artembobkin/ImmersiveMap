// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class CameraFlightOverviewProfileTests: XCTestCase {
    // Токио -> Дубай из демо-раскадровки: примерно четверть мира по долготе.
    private let tokyo = ImmersiveMapProjection.worldMercator(latitude: 35.6595 * .pi / 180,
                                                             longitude: 139.7005 * .pi / 180)
    private let dubai = ImmersiveMapProjection.worldMercator(latitude: 25.1972 * .pi / 180,
                                                             longitude: 55.2744 * .pi / 180)

    private func makeCityToCityProfile() -> CameraFlightMath.OverviewFlightProfile? {
        let distance = CameraFlightMath.greatCircleRouteDistance(from: tokyo, to: dubai)
        return CameraFlightMath.OverviewFlightProfile.make(startZoom: 16.7,
                                                           targetZoom: 16.4,
                                                           normalizedWorldDistance: distance)
    }

    func testProfileMatchesEndpoints() throws {
        let profile = try XCTUnwrap(makeCityToCityProfile())
        let start = profile.sample(atProgress: 0)
        let end = profile.sample(atProgress: 1)
        XCTAssertEqual(start.zoom, 16.7, accuracy: 1e-6)
        XCTAssertEqual(start.panProgress, 0, accuracy: 1e-6)
        XCTAssertEqual(end.zoom, 16.4, accuracy: 1e-3)
        XCTAssertEqual(end.panProgress, 1, accuracy: 1e-3)
    }

    func testLongFlightPullsOutToGlobe() throws {
        let profile = try XCTUnwrap(makeCityToCityProfile())
        let apexZoom = (0...100)
            .map { profile.sample(atProgress: Double($0) / 100).zoom }
            .min() ?? .infinity
        // Межконтинентальный перелёт обязан подняться до вида глобуса.
        XCTAssertLessThan(apexZoom, 4)
        XCTAssertGreaterThanOrEqual(apexZoom, 0)
    }

    func testShortFlightArcsModestly() throws {
        // Соседние кварталы: около 400 м, дуга не должна улетать на глобус.
        let profile = try XCTUnwrap(
            CameraFlightMath.OverviewFlightProfile.make(startZoom: 16.5,
                                                        targetZoom: 16.5,
                                                        normalizedWorldDistance: 1e-5)
        )
        let apexZoom = (0...100)
            .map { profile.sample(atProgress: Double($0) / 100).zoom }
            .min() ?? .infinity
        XCTAssertGreaterThan(apexZoom, 12)
        XCTAssertLessThan(apexZoom, 16.5)
    }

    func testPanProgressIsMonotonic() throws {
        let profile = try XCTUnwrap(makeCityToCityProfile())
        var previous = -Double.infinity
        for step in 0...200 {
            let panProgress = profile.sample(atProgress: Double(step) / 200).panProgress
            XCTAssertGreaterThanOrEqual(panProgress, previous)
            previous = panProgress
        }
    }

    func testPanCrawlsNearGroundAndCruisesAtApex() throws {
        let profile = try XCTUnwrap(makeCityToCityProfile())
        // На первой десятой пути (у земли) центр почти не двигается,
        // середина перелёта (апекс) покрывает основную дистанцию.
        let nearGround = profile.sample(atProgress: 0.1).panProgress
        let beforeMiddle = profile.sample(atProgress: 0.35).panProgress
        let afterMiddle = profile.sample(atProgress: 0.65).panProgress
        XCTAssertLessThan(nearGround, 0.01)
        XCTAssertGreaterThan(afterMiddle - beforeMiddle, 0.5)
    }

    func testDegenerateDistanceReturnsNil() {
        XCTAssertNil(CameraFlightMath.OverviewFlightProfile.make(startZoom: 3,
                                                                 targetZoom: 15,
                                                                 normalizedWorldDistance: 0))
    }

    func testRouteDistancesAgreeInScale() {
        // Обе метрики в нормализованных мировых единицах: для экваториальных
        // точек без наклона дуга и mercator-путь близки по длине.
        let a = ImmersiveMapProjection.worldMercator(latitude: 0, longitude: 0)
        let b = ImmersiveMapProjection.worldMercator(latitude: 0, longitude: .pi / 2)
        let mercator = CameraFlightMath.mercatorRouteDistance(from: a, to: b)
        let greatCircle = CameraFlightMath.greatCircleRouteDistance(from: a, to: b)
        XCTAssertEqual(mercator, 0.25, accuracy: 1e-9)
        XCTAssertEqual(greatCircle, 0.25, accuracy: 1e-9)
    }

    func testAnimatorOverviewFlightDipsZoomAndArrives() throws {
        let animator = CameraFlightAnimator()
        let startState = ImmersiveMapCameraState(centerWorldMercator: tokyo,
                                                 zoom: 16.7,
                                                 bearing: 0.55,
                                                 pitch: 1.02)
        let targetState = ImmersiveMapCameraState(centerWorldMercator: dubai,
                                                  zoom: 16.4,
                                                  bearing: -0.35,
                                                  pitch: 1.0)
        XCTAssertTrue(animator.start(from: startState,
                                     to: targetState,
                                     duration: 6.0,
                                     routeStyle: .greatCircle,
                                     altitudeStyle: .overviewFirst,
                                     currentTime: 0))

        var minZoom = Double.infinity
        var lastState: ImmersiveMapCameraState?
        for step in 1...120 {
            guard let stepResult = animator.advance(currentTime: 6.0 * Double(step) / 120) else {
                break
            }
            minZoom = min(minZoom, stepResult.cameraState.zoom)
            lastState = stepResult.cameraState
        }

        XCTAssertLessThan(minZoom, 4)
        let finalState = try XCTUnwrap(lastState)
        XCTAssertEqual(finalState.zoom, 16.4, accuracy: 1e-3)
        XCTAssertEqual(finalState.centerWorldMercator.x, dubai.x, accuracy: 1e-6)
        XCTAssertEqual(finalState.centerWorldMercator.y, dubai.y, accuracy: 1e-6)
        XCTAssertFalse(animator.isActive)
    }
}

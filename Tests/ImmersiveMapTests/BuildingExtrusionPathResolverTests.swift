// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class BuildingExtrusionPathResolverTests: XCTestCase {
    func testTranslucentModeCompositesWithStyleAlphaAtAnyZoom() {
        let style = makeStyle(mode: .translucent, alpha: 0.6)

        XCTAssertEqual(BuildingExtrusionPathResolver.resolve(style: style, zoom: 3.0),
                       .composited(alpha: 0.6))
        XCTAssertEqual(BuildingExtrusionPathResolver.resolve(style: style, zoom: 19.5),
                       .composited(alpha: 0.6))
    }

    func testSolidModeDrawsDirectlyAtAnyZoom() {
        let style = makeStyle(mode: .solid, alpha: 0.6)

        XCTAssertEqual(BuildingExtrusionPathResolver.resolve(style: style, zoom: 3.0), .solid)
        XCTAssertEqual(BuildingExtrusionPathResolver.resolve(style: style, zoom: 19.5), .solid)
    }

    func testSolidAtHighZoomIsTranslucentUpToStartZoom() {
        let style = makeStyle(mode: .solidAtHighZoom(startZoom: 17.0, endZoom: 18.0), alpha: 0.6)

        XCTAssertEqual(BuildingExtrusionPathResolver.resolve(style: style, zoom: 14.0),
                       .composited(alpha: 0.6))
        XCTAssertEqual(BuildingExtrusionPathResolver.resolve(style: style, zoom: 17.0),
                       .composited(alpha: 0.6))
    }

    func testSolidAtHighZoomInterpolatesAlphaInsideTransition() {
        let style = makeStyle(mode: .solidAtHighZoom(startZoom: 17.0, endZoom: 18.0), alpha: 0.6)

        guard case .composited(let alpha) = BuildingExtrusionPathResolver.resolve(style: style, zoom: 17.5) else {
            return XCTFail("Внутри перехода ожидается composited-путь")
        }
        XCTAssertEqual(alpha, 0.8, accuracy: 1e-4)
    }

    func testSolidAtHighZoomBecomesSolidFromEndZoom() {
        let style = makeStyle(mode: .solidAtHighZoom(startZoom: 17.0, endZoom: 18.0), alpha: 0.6)

        XCTAssertEqual(BuildingExtrusionPathResolver.resolve(style: style, zoom: 18.0), .solid)
        XCTAssertEqual(BuildingExtrusionPathResolver.resolve(style: style, zoom: 19.7), .solid)
    }

    func testSolidAtHighZoomWithDegenerateRangeActsAsStep() {
        let style = makeStyle(mode: .solidAtHighZoom(startZoom: 17.0, endZoom: 17.0), alpha: 0.6)

        XCTAssertEqual(BuildingExtrusionPathResolver.resolve(style: style, zoom: 16.9),
                       .composited(alpha: 0.6))
        XCTAssertEqual(BuildingExtrusionPathResolver.resolve(style: style, zoom: 17.1), .solid)
    }

    func testSolidAtHighZoomDefaultUsesZoom17To18Range() {
        XCTAssertEqual(ImmersiveMapSettings.StyleSettings.BuildingExtrusionMode.solidAtHighZoom,
                       .solidAtHighZoom(startZoom: 17.0, endZoom: 18.0))
    }

    private func makeStyle(mode: ImmersiveMapSettings.StyleSettings.BuildingExtrusionMode,
                           alpha: Float) -> ImmersiveMapSettings.StyleSettings {
        var style = ImmersiveMapSettings.default.style
        style.buildingExtrusionMode = mode
        style.buildingExtrusionAlpha = alpha
        return style
    }
}

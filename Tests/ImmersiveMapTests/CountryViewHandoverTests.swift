// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The country view arrives as one change: the land cover and the biomes
/// fade out over zoom 6.7 to 7.1, and inside that fade the roads switch from
/// the globe's highway yellow under its veil to their own look, at once.
final class CountryViewHandoverTests: XCTestCase {
    private let style = ProtomapsBasemapDefaultMapStyle()

    func testTheRoadsSwitchWhileTheLandCoverFades() throws {
        let fade = ProtomapsBasemapDefaultMapStyle.landcoverZoomFade
        let switchZoom = ProtomapsBasemapDefaultMapStyle.roadLookSwitchZoom
        XCTAssertEqual(fade.alpha(atZoom: 6.7), 1, accuracy: 1e-6)
        XCTAssertEqual(fade.alpha(atZoom: 7.1), 0, accuracy: 1e-6)
        let atSwitch = fade.alpha(atZoom: Double(switchZoom))
        XCTAssertTrue(atSwitch > 0 && atSwitch < 1, "the roads switch inside the cover's fade")

        let road = style.overviewRoadStyle(.init(fillKey: 60, priority: 1),
                                           roadClass: .motorway,
                                           name: "",
                                           color: SIMD4<Float>(0.5, 0.5, 0.5, 1),
                                           tileZoom: 7,
                                           tunnel: false)
        let pass = try XCTUnwrap(road.lineStyle?.pass ?? road.roadStyle?.fill)
        XCTAssertEqual(pass.sphereLookUntilZoom, switchZoom)
        XCTAssertNotNil(pass.sphereColor, "the road wears the globe's highway yellow up to the switch")
        XCTAssertLessThan(pass.sphereAlpha, 1, "and its veil, which stays translucent until it switches")
    }

    /// The switch zoom rides to the GPU, and a stroke without one has none.
    func testTheLineStyleCarriesTheSwitchZoom() {
        let geometry = LineGeometryStyle(lineWidth: 4, lineCapRound: true, lineJoinRound: true)
        let switching = LinePass(key: 1, color: SIMD4<Float>(0.5, 0.5, 0.5, 1),
                                 sphereAlpha: 0.6,
                                 sphereColor: SIMD3<Float>(1, 0.8, 0.3),
                                 sphereLookUntilZoom: 7,
                                 lineGeometry: geometry)
        XCTAssertEqual(TileUnificationStage.makeTileLineStyle(from: switching).sphereLookUntilZoom, 7)

        let plain = LinePass(key: 2, color: SIMD4<Float>(0.5, 0.5, 0.5, 1), lineGeometry: geometry)
        XCTAssertEqual(TileUnificationStage.makeTileLineStyle(from: plain).sphereLookUntilZoom, 0)
    }
}

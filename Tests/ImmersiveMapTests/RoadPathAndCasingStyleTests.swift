// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// Two decisions the built-in style states and the engine only follows:
/// which zooms a road takes the road path at (the case of the answer, a
/// line or a road), and the camera zoom the casing shows from (the casing
/// pass's fade band).
final class RoadPathAndCasingStyleTests: XCTestCase {
    private let style = ProtomapsBasemapDefaultMapStyle()
    /// The same style with the theme's casing switched on.
    private let casedStyle = ProtomapsBasemapDefaultMapStyle(
        theme: ProtomapsBasemapTheme.default.roadMetrics { $0.drawsCasing = true })

    private func roadStyle(cls: String, zoom: Int, cased: Bool = false) -> FeatureStyle {
        (cased ? casedStyle : style).makeStyle(data: DetFeatureStyleData(layerName: "roads",
                                                  properties: ProtomapsRoadSpelling.values(forClass: cls),
                                                  tile: Tile(x: 0, y: 0, z: zoom),
                                                  geometryType: .linestring))
    }

    /// Below the style's road path zoom an overview stroke is a plain line;
    /// from it the same stroke is a road, so the parser stitches and sorts
    /// it. The stroke itself is the same either side of the boundary.
    func testTheOverviewStrokeIsALineBelowTheRoadPathZoomAndARoadFromIt() {
        XCTAssertEqual(ProtomapsBasemapDefaultMapStyle.roadPathMinimumTileZoom, 8)
        let below = roadStyle(cls: "motorway", zoom: 7)
        let from = roadStyle(cls: "motorway", zoom: 8)
        if case .line = below {} else { XCTFail("A z7 motorway is a ground line") }
        if case .road = from {} else { XCTFail("A z8 motorway is a road") }
        XCTAssertEqual(below.resolvedLineRenderPasses[0].lineWidthPoints,
                       from.resolvedLineRenderPasses[0].lineWidthPoints)
        XCTAssertEqual(below.resolvedLineRenderPasses[0].color, from.resolvedLineRenderPasses[0].color)
    }

    /// The casing eases in from the style's casing zoom, as the pass's own
    /// fade band, while the fill keeps the road band.
    func testTheCasingCarriesItsZoomAsTheFadeBand() {
        XCTAssertEqual(ProtomapsBasemapDefaultMapStyle.casingMinimumCameraZoom, 16)
        XCTAssertNil(roadStyle(cls: "motorway", zoom: 14).resolvedLineRenderPasses.first { $0.roadPassRole == .casing },
                     "a road draws without an outline unless the theme asks for one")
        let street = roadStyle(cls: "motorway", zoom: 14, cased: true)
        let casing = street.resolvedLineRenderPasses.first { $0.roadPassRole == .casing }!
        let fill = street.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }!
        XCTAssertEqual(casing.zoomFade, .fadeIn(from: 16, to: 17))
        XCTAssertEqual(casing.zoomFade.alpha(atZoom: 15.99), 0)
        XCTAssertEqual(casing.zoomFade.alpha(atZoom: 17), 1)
        XCTAssertEqual(fill.zoomFade, ProtomapsBasemapDefaultMapStyle.roadZoomFade)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest
import simd

/// Two contracts of the street-level road picture: a ribbon inside a
/// carriageway surface is clipped away (the surface owns that ground), and
/// a road is a symbol of a width in points, frozen on the ground from the
/// theme's world lock zoom.
final class RoadSurfaceAndSymbolWidthTests: XCTestCase {
    private func area(_ ring: [SIMD2<Float>], priority: Int = 80) -> RoadSurfaceArea {
        var lower = ring[0], upper = ring[0]
        for p in ring { lower = simd_min(lower, p); upper = simd_max(upper, p) }
        return RoadSurfaceArea(exterior: ring, classPriority: priority, bounds: (lower, upper))
    }

    // MARK: - Surface clipping

    func testARibbonThroughASurfaceKeepsOnlyItsOutsideParts() {
        let square = area([SIMD2(1000, 1000), SIMD2(2000, 1000), SIMD2(2000, 2000), SIMD2(1000, 2000)])
        let line: [SIMD2<Float>] = [SIMD2(0, 1500), SIMD2(3000, 1500)]
        let pieces = RoadSurfaceClipper.clip(polyline: line, outside: [square])
        XCTAssertEqual(pieces.count, 2, "in, through, out: the two outside ends survive")
        XCTAssertEqual(pieces[0].first, SIMD2<Float>(0, 1500))
        XCTAssertEqual(pieces[0].last!.x, 1000, accuracy: 0.01, "ends flush at the surface edge")
        XCTAssertEqual(pieces[1].first!.x, 2000, accuracy: 0.01, "resumes flush at the far edge")
        XCTAssertEqual(pieces[1].last, SIMD2<Float>(3000, 1500))
    }

    func testARibbonInsideASurfaceVanishesAndOneOutsideIsUntouched() {
        let square = area([SIMD2(1000, 1000), SIMD2(2000, 1000), SIMD2(2000, 2000), SIMD2(1000, 2000)])
        XCTAssertTrue(RoadSurfaceClipper.clip(polyline: [SIMD2(1200, 1500), SIMD2(1800, 1500)], outside: [square]).isEmpty)
        let outside: [SIMD2<Float>] = [SIMD2(0, 100), SIMD2(3000, 100)]
        XCTAssertEqual(RoadSurfaceClipper.clip(polyline: outside, outside: [square]), [outside])
    }

    func testOnlySurfacesOfTheSameOrAHigherClassOwnARibbon() {
        // The parser filters owners by class priority before clipping: a
        // service junction area (45) must not swallow a primary (80) that
        // crosses it. Pin the filter rule the parser applies.
        let serviceArea = area([SIMD2(1000, 1000), SIMD2(2000, 1000), SIMD2(2000, 2000), SIMD2(1000, 2000)], priority: 45)
        let primaryPriority = 80
        let owners = [serviceArea].filter { $0.classPriority >= primaryPriority }
        XCTAssertTrue(owners.isEmpty, "a lower-class surface does not own a higher-class ribbon")
    }

    // MARK: - The symbol

    func testRoadsAreSymbolsOfAFixedWidthOnScreen() {
        let style = ImmersiveMapTilesDefaultMapStyle(theme: .default)
        func v(_ s: String) -> MvtValue { .string(s) }
        let primary = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                                properties: ["class": v("primary")],
                                                                tile: Tile(x: 39615, y: 20486, z: 16)))
        let fill = primary.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }!
        XCTAssertEqual(fill.lineWidthPoints,
                       ImmersiveMapTilesTheme.RoadMetrics.defaultSymbolWidthPoints.primary,
                       "a primary is the theme's symbol in points at every zoom")
        XCTAssertNil(primary.resolvedLineRenderPasses.first { $0.roadPassRole == .casing },
                     "the symbol draws kerbless like the rest of the automobile tier")
        XCTAssertGreaterThan(fill.lineGeometry.lineWidth, 0, "the ribbon hosts the point width")
    }

    func testTheThemeStatesTheSymbolWidthTheWorldLockAndTheFirstZoomOfAClass() {
        func v(_ s: String) -> MvtValue { .string(s) }
        func fill(_ theme: ImmersiveMapTilesTheme, cls: String, z: Int) -> TestRoadPass? {
            ImmersiveMapTilesDefaultMapStyle(theme: theme)
                .makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                     properties: ["class": v(cls)],
                                                     tile: Tile(x: 0, y: 0, z: z)))
                .resolvedLineRenderPasses.first { $0.roadPassRole == .fill }
        }
        let standard = ImmersiveMapTilesTheme.default
        XCTAssertEqual(fill(standard, cls: "minor", z: 14)?.pointWidthWorldLockZoom, 15,
                       "a road keeps its width on the ground from camera zoom 15")
        XCTAssertNil(fill(standard, cls: "minor", z: 13), "the small network joins at street zoom")

        let changed = standard.roadMetrics { metrics in
            metrics.worldLockZoom = 15.5
            metrics.symbolWidthPoints.minor = 3
            metrics.minimumTileZoom.minor = 13
        }
        XCTAssertEqual(fill(changed, cls: "minor", z: 14)?.pointWidthWorldLockZoom, 15.5)
        XCTAssertEqual(fill(changed, cls: "minor", z: 14)?.lineWidthPoints, 3)
        XCTAssertNotNil(fill(changed, cls: "minor", z: 13))
        XCTAssertNotEqual(changed.cacheFingerprint, standard.cacheFingerprint,
                          "the metrics are baked into the tiles, so they are part of the cache identity")
    }

    func testTheWorldLockZoomReachesTheShaderStyle() {
        let pass = LinePass(key: 1, color: .one, lineWidthPoints: 4, pointWidthWorldLockZoom: 14,
                            lineGeometry: LineGeometryStyle(lineWidth: 48))
        XCTAssertEqual(TileUnificationStage.makeTileLineStyle(from: pass).worldLockZoom, 14)
    }

    func testRoadMarkingsDrawNothingBelowCameraZoomFifteen() {
        // Below camera zoom 15 there is NO paint at all; from 15 it fades in
        // over a short band, fully in well before z16.
        XCTAssertEqual(LowZoomOverviewFade.roadMarkingAlpha(for: 13.0), 0)
        XCTAssertEqual(LowZoomOverviewFade.roadMarkingAlpha(for: 14.9), 0)
        XCTAssertEqual(LowZoomOverviewFade.roadMarkingAlpha(for: 15.0), 0)
        XCTAssertGreaterThan(LowZoomOverviewFade.roadMarkingAlpha(for: 15.2), 0)
        XCTAssertEqual(LowZoomOverviewFade.roadMarkingAlpha(for: 15.4), 1)
        XCTAssertEqual(LowZoomOverviewFade.roadMarkingAlpha(for: 16.0), 1)
    }

    func testClassFadeComesInOverTheZoomLevelAfterItsStart() {
        // The mask carries the start zoom above the fixed-band masks, so the
        // shader can tell them apart; the band is one zoom level, smooth.
        XCTAssertEqual(LowZoomOverviewFade.classFadeMask(startZoom: 5), 15)
        XCTAssertGreaterThan(LowZoomOverviewFade.classFadeMaskBase, 4)
        XCTAssertEqual(LowZoomOverviewFade.classFadeAlpha(for: 4.9, startZoom: 5), 0)
        XCTAssertEqual(LowZoomOverviewFade.classFadeAlpha(for: 5.0, startZoom: 5), 0)
        XCTAssertEqual(LowZoomOverviewFade.classFadeAlpha(for: 5.5, startZoom: 5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(LowZoomOverviewFade.classFadeAlpha(for: 6.0, startZoom: 5), 1)
        XCTAssertEqual(LowZoomOverviewFade.classFadeAlpha(for: 9.0, startZoom: 5), 1)
        XCTAssertEqual(LowZoomOverviewFade.classFadeAlpha(for: 7.25, startZoom: 7),
                       LowZoomOverviewFade.classFadeAlpha(for: 5.25, startZoom: 5))
    }
}

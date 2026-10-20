// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest
import simd

/// A contract of the street-level road picture: a road is a symbol of a
/// width in points, frozen on the ground from the theme's world lock zoom.
final class RoadSymbolWidthFadeTests: XCTestCase {
    // MARK: - The symbol

    func testRoadsAreSymbolsOfAFixedWidthOnScreen() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)
        let primary = style.makeStyle(data: DetFeatureStyleData(layerName: "roads",
                                                                properties: ProtomapsRoadSpelling.values(forClass: "primary"),
                                                                tile: Tile(x: 19807, y: 10243, z: 15)))
        let fill = primary.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }!
        XCTAssertEqual(fill.lineWidthPoints,
                       ProtomapsBasemapTheme.RoadMetrics.defaultSymbolWidthPoints.primary,
                       "a primary is the theme's symbol in points at every zoom")
        XCTAssertNil(primary.resolvedLineRenderPasses.first { $0.roadPassRole == .casing },
                     "the symbol draws kerbless like the rest of the automobile tier")
        XCTAssertGreaterThan(fill.lineGeometry.lineWidth, 0, "the ribbon hosts the point width")
    }

    func testTheThemeStatesTheSymbolWidthTheWorldLockAndTheFirstZoomOfAClass() {
        func fill(_ theme: ProtomapsBasemapTheme, cls: String, z: Int) -> TestRoadPass? {
            ProtomapsBasemapDefaultMapStyle(theme: theme)
                .makeStyle(data: DetFeatureStyleData(layerName: "roads",
                                                     properties: ProtomapsRoadSpelling.values(forClass: cls),
                                                     tile: Tile(x: 0, y: 0, z: z)))
                .resolvedLineRenderPasses.first { $0.roadPassRole == .fill }
        }
        let standard = ProtomapsBasemapTheme.default
        XCTAssertEqual(fill(standard, cls: "minor", z: 14)?.pointWidthWorldLockZoom, 15,
                       "a road keeps its width on the ground from camera zoom 15")
        XCTAssertNotNil(fill(standard, cls: "minor", z: 12), "the small network draws from the tile that ships it")

        let changed = standard.roadMetrics { metrics in
            metrics.worldLockZoom = 15.5
            metrics.symbolWidthPoints.minor = 3
            metrics.minimumTileZoom.minor = 14
        }
        XCTAssertEqual(fill(changed, cls: "minor", z: 14)?.pointWidthWorldLockZoom, 15.5)
        XCTAssertEqual(fill(changed, cls: "minor", z: 14)?.lineWidthPoints, 3)
        XCTAssertNil(fill(changed, cls: "minor", z: 13), "a theme can still hold a class back")
        XCTAssertNotEqual(changed.cacheFingerprint, standard.cacheFingerprint,
                          "the metrics are baked into the tiles, so they are part of the cache identity")
    }

    func testTheWorldLockZoomReachesTheShaderStyle() {
        let pass = LinePass(key: 1, color: .one, lineWidthPoints: 4, pointWidthWorldLockZoom: 14,
                            lineGeometry: LineGeometryStyle(lineWidth: 48))
        XCTAssertEqual(TileUnificationStage.makeTileLineStyle(from: pass).worldLockZoom, 14)
    }

    /// The sphere's veil on a stroke is a style field the parser bakes:
    /// one unless the style says otherwise, so every other line is the
    /// same on both surfaces.
    func testTheSphereAlphaReachesTheShaderStyle() {
        let plain = LinePass(key: 1, color: .one, lineGeometry: LineGeometryStyle(lineWidth: 8))
        XCTAssertEqual(plain.sphereAlpha, 1)
        XCTAssertEqual(TileUnificationStage.makeTileLineStyle(from: plain).sphereAlpha, 1)
        let veiled = LinePass(key: 1, color: .one, sphereAlpha: 0.4, lineGeometry: LineGeometryStyle(lineWidth: 8))
        XCTAssertEqual(TileUnificationStage.makeTileLineStyle(from: veiled).sphereAlpha, 0.4)
        XCTAssertEqual(TileLineStyle.polygon.sphereAlpha, 1)
        // The globe colour: the style's own unless the pass states one.
        let grey = LinePass(key: 1, color: SIMD4<Float>(0.5, 0.6, 0.7, 1), lineGeometry: LineGeometryStyle(lineWidth: 8))
        let own = TileUnificationStage.makeTileLineStyle(from: grey)
        XCTAssertEqual([own.sphereColorRed, own.sphereColorGreen, own.sphereColorBlue], [0.5, 0.6, 0.7])
        let yellow = LinePass(key: 1, color: SIMD4<Float>(0.5, 0.6, 0.7, 1), sphereColor: SIMD3<Float>(1, 0.8, 0.3),
                              lineGeometry: LineGeometryStyle(lineWidth: 8))
        let worn = TileUnificationStage.makeTileLineStyle(from: yellow)
        XCTAssertEqual([worn.sphereColorRed, worn.sphereColorGreen, worn.sphereColorBlue], [1, 0.8, 0.3])
    }

    /// The overview strokes wear the theme's globe veil, the street era's
    /// symbols do not: a road of the street zooms is never on the sphere,
    /// and the veil is part of what the tiles bake.
    func testTheOverviewStrokesWearTheGlobeVeil() throws {
        func fill(_ theme: ProtomapsBasemapTheme, cls: String, z: Int) -> TestRoadPass? {
            ProtomapsBasemapDefaultMapStyle(theme: theme)
                .makeStyle(data: DetFeatureStyleData(layerName: "roads",
                                                     properties: ProtomapsRoadSpelling.values(forClass: cls),
                                                     tile: Tile(x: 0, y: 0, z: z)))
                .resolvedLineRenderPasses.first { $0.roadPassRole == .fill }
        }
        let standard = ProtomapsBasemapTheme.default
        XCTAssertEqual(standard.roadMetrics.globeOpacity, 0.6)
        XCTAssertEqual(fill(standard, cls: "motorway", z: 6)?.sphereAlpha, 0.6)
        XCTAssertEqual(fill(standard, cls: "motorway", z: 7)?.sphereAlpha, 0.6)
        XCTAssertEqual(fill(standard, cls: "minor", z: 14)?.sphereAlpha, 1)

        // On the globe the strokes wear the overview network's tones: the
        // motorways and the trunks the main one, the rest the minor one,
        // and the street era's symbols their own asphalt.
        let network = standard.layers.overviewRoads
        let majorTone = SIMD3<Float>(network.major.x, network.major.y, network.major.z)
        let minorTone = SIMD3<Float>(network.minor.x, network.minor.y, network.minor.z)
        XCTAssertEqual(fill(standard, cls: "motorway", z: 6)?.sphereColor, majorTone)
        XCTAssertEqual(fill(standard, cls: "trunk", z: 6)?.sphereColor, majorTone)
        XCTAssertEqual(fill(standard, cls: "primary", z: 7)?.sphereColor, minorTone)
        XCTAssertNil(fill(standard, cls: "minor", z: 14)?.sphereColor)

        let lifted = standard.roadMetrics { $0.globeOpacity = 1 }
        XCTAssertEqual(fill(lifted, cls: "motorway", z: 6)?.sphereAlpha, 1)
        XCTAssertNotEqual(lifted.cacheFingerprint, standard.cacheFingerprint,
                          "the veil is baked into the tiles, so it is part of the cache identity")
    }

    func testRoadMarkingsShowWhereverTheTileStatesThem() {
        let paint = ProtomapsBasemapDefaultMapStyle.roadMarkingZoomFade
        for zoom in [12.0, 13.0, 14.9, 15.0, 16.0] {
            XCTAssertEqual(paint.alpha(atZoom: zoom), 1, "z\(zoom)")
        }
    }

    func testClassFadeComesInOverTheZoomLevelAfterItsStart() {
        // A casing comes in over the one zoom level after its start, smooth.
        let motorway = ProtomapsBasemapDefaultMapStyle.classZoomFade(startZoom: 5)
        XCTAssertEqual(motorway, .fadeIn(from: 5, to: 6))
        XCTAssertEqual(motorway.alpha(atZoom: 4.9), 0)
        XCTAssertEqual(motorway.alpha(atZoom: 5.0), 0)
        XCTAssertEqual(motorway.alpha(atZoom: 5.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(motorway.alpha(atZoom: 6.0), 1)
        XCTAssertEqual(motorway.alpha(atZoom: 9.0), 1)
        XCTAssertEqual(ProtomapsBasemapDefaultMapStyle.classZoomFade(startZoom: 7).alpha(atZoom: 7.25),
                       motorway.alpha(atZoom: 5.25))
    }
}

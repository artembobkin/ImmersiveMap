// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

/// The region-to-tile conversion decides what an offline download stores and
/// what removal keeps, so its edges (antimeridian, poles, the east edge at
/// longitude 180) must match the slippy tile scheme exactly.
final class OfflineRegionTileMathTests: XCTestCase {
    func testWholeWorldCoversEveryTilePerZoom() {
        let region = ImmersiveMapOfflineRegion(id: "world",
                                               southWest: GeoCoordinate(latitude: -90, longitude: -180),
                                               northEast: GeoCoordinate(latitude: 90, longitude: 180),
                                               zoomLevels: 0...2)
        XCTAssertEqual(OfflineRegionTileMath.tileCount(in: region), 1 + 4 + 16)

        let coverage = OfflineRegionTileMath.coverage(of: region)
        XCTAssertEqual(coverage.map(\.zoom), [0, 1, 2])
        XCTAssertEqual(coverage[2].xRanges, [0...3])
        XCTAssertEqual(coverage[2].yRange, 0...3)
    }

    func testMatchesReferenceSlippyFormulaForCityRegion() {
        // Independent derivation of the same scheme: x from the linear
        // longitude fraction, y from asinh(tan(lat)), which equals the
        // artanh(sin(lat)) form used by the production projection.
        func referenceTileX(longitude: Double, zoom: Int) -> Int {
            let n = Double(1 << zoom)
            return min(max(Int(floor((longitude + 180.0) / 360.0 * n)), 0), (1 << zoom) - 1)
        }
        func referenceTileY(latitude: Double, zoom: Int) -> Int {
            let n = Double(1 << zoom)
            let latitudeRadians = latitude * .pi / 180.0
            let y = (1.0 - asinh(tan(latitudeRadians)) / .pi) / 2.0
            return min(max(Int(floor(y * n)), 0), (1 << zoom) - 1)
        }

        let region = ImmersiveMapOfflineRegion(id: "london",
                                               southWest: GeoCoordinate(latitude: 51.35, longitude: -0.35),
                                               northEast: GeoCoordinate(latitude: 51.65, longitude: 0.10),
                                               zoomLevels: 14...14)
        guard let coverage = OfflineRegionTileMath.coverage(of: region).first else {
            return XCTFail("Expected coverage for zoom 14")
        }
        XCTAssertEqual(coverage.xRanges,
                       [referenceTileX(longitude: -0.35, zoom: 14)...referenceTileX(longitude: 0.10, zoom: 14)])
        XCTAssertEqual(coverage.yRange,
                       referenceTileY(latitude: 51.65, zoom: 14)...referenceTileY(latitude: 51.35, zoom: 14))
    }

    func testTinyRegionAroundOriginCoversTheFourQuadrantTiles() {
        let region = ImmersiveMapOfflineRegion(id: "origin",
                                               southWest: GeoCoordinate(latitude: -0.0001, longitude: -0.0001),
                                               northEast: GeoCoordinate(latitude: 0.0001, longitude: 0.0001),
                                               zoomLevels: 1...1)
        let tiles = OfflineRegionTileMath.tileSet(in: region)
        XCTAssertEqual(tiles, [Tile(x: 0, y: 0, z: 1),
                               Tile(x: 1, y: 0, z: 1),
                               Tile(x: 0, y: 1, z: 1),
                               Tile(x: 1, y: 1, z: 1)])
    }

    func testAntimeridianCrossingSplitsIntoTwoRanges() {
        let region = ImmersiveMapOfflineRegion(id: "fiji",
                                               southWest: GeoCoordinate(latitude: -20, longitude: 170),
                                               northEast: GeoCoordinate(latitude: -15, longitude: -170),
                                               zoomLevels: 2...2)
        guard let coverage = OfflineRegionTileMath.coverage(of: region).first else {
            return XCTFail("Expected coverage for zoom 2")
        }
        XCTAssertEqual(coverage.xRanges, [3...3, 0...0])
    }

    func testAntimeridianCrossingMergesIntoFullRowAtCoarseZoom() {
        // At zoom 0 both sides of the antimeridian are the same single tile;
        // two ranges would count it twice.
        let region = ImmersiveMapOfflineRegion(id: "fiji",
                                               southWest: GeoCoordinate(latitude: -20, longitude: 170),
                                               northEast: GeoCoordinate(latitude: -15, longitude: -170),
                                               zoomLevels: 0...0)
        XCTAssertEqual(OfflineRegionTileMath.coverage(of: region).first?.xRanges, [0...0])
        XCTAssertEqual(OfflineRegionTileMath.tileCount(in: region), 1)
    }

    func testEastEdgeAtLongitude180StaysInTheLastColumn() {
        let region = ImmersiveMapOfflineRegion(id: "chukotka",
                                               southWest: GeoCoordinate(latitude: 60, longitude: 179),
                                               northEast: GeoCoordinate(latitude: 66, longitude: 180),
                                               zoomLevels: 2...2)
        XCTAssertEqual(OfflineRegionTileMath.coverage(of: region).first?.xRanges, [3...3])
    }

    func testPolarLatitudesClampToMercatorRange() {
        let region = ImmersiveMapOfflineRegion(id: "arctic",
                                               southWest: GeoCoordinate(latitude: 84, longitude: -10),
                                               northEast: GeoCoordinate(latitude: 90, longitude: 10),
                                               zoomLevels: 3...3)
        guard let coverage = OfflineRegionTileMath.coverage(of: region).first else {
            return XCTFail("Expected coverage for zoom 3")
        }
        XCTAssertEqual(coverage.yRange.lowerBound, 0)
    }

    func testInvertedLatitudesProduceNoTiles() {
        let region = ImmersiveMapOfflineRegion(id: "inverted",
                                               southWest: GeoCoordinate(latitude: 10, longitude: 0),
                                               northEast: GeoCoordinate(latitude: 5, longitude: 5),
                                               zoomLevels: 0...4)
        XCTAssertEqual(OfflineRegionTileMath.tileCount(in: region), 0)
        XCTAssertTrue(OfflineRegionTileMath.tiles(in: region).isEmpty)
    }

    func testTileEnumerationMatchesCountAndStartsCoarse() {
        let region = ImmersiveMapOfflineRegion(id: "alps",
                                               southWest: GeoCoordinate(latitude: 45.6, longitude: 6.4),
                                               northEast: GeoCoordinate(latitude: 47.9, longitude: 13.1),
                                               zoomLevels: 0...8)
        let tiles = OfflineRegionTileMath.tiles(in: region)
        XCTAssertEqual(tiles.count, OfflineRegionTileMath.tileCount(in: region))
        XCTAssertEqual(tiles.map(\.z), tiles.map(\.z).sorted())
        XCTAssertEqual(tiles.first?.z, 0)
        XCTAssertEqual(Set(tiles).count, tiles.count)
    }

    func testUnwrappedLongitudesBeyond180NormalizeToAnAntimeridianCrossing() {
        // A caller may build "center plus offset" bounds near the
        // antimeridian without wrapping; 179.72...180.08 must mean the same
        // sliver as 179.72...-179.92.
        let unwrapped = ImmersiveMapOfflineRegion(id: "sliver",
                                                  southWest: GeoCoordinate(latitude: 60, longitude: 179.72),
                                                  northEast: GeoCoordinate(latitude: 66, longitude: 180.08),
                                                  zoomLevels: 4...4)
        let wrapped = ImmersiveMapOfflineRegion(id: "sliver",
                                                southWest: GeoCoordinate(latitude: 60, longitude: 179.72),
                                                northEast: GeoCoordinate(latitude: 66, longitude: -179.92),
                                                zoomLevels: 4...4)
        XCTAssertEqual(OfflineRegionTileMath.coverage(of: unwrapped),
                       OfflineRegionTileMath.coverage(of: wrapped))
        XCTAssertEqual(OfflineRegionTileMath.coverage(of: unwrapped).first?.xRanges, [15...15, 0...0])
    }

    func testNonFiniteCoordinatesProduceNoTilesInsteadOfTrapping() {
        for badValue in [Double.nan, .infinity, -.infinity] {
            let region = ImmersiveMapOfflineRegion(id: "bad",
                                                   southWest: GeoCoordinate(latitude: 0, longitude: badValue),
                                                   northEast: GeoCoordinate(latitude: 1, longitude: 1),
                                                   zoomLevels: 0...4)
            XCTAssertEqual(OfflineRegionTileMath.tileCount(in: region), 0)
        }
        let badLatitude = ImmersiveMapOfflineRegion(id: "bad",
                                                    southWest: GeoCoordinate(latitude: .nan, longitude: 0),
                                                    northEast: GeoCoordinate(latitude: 1, longitude: 1),
                                                    zoomLevels: 0...4)
        XCTAssertEqual(OfflineRegionTileMath.tileCount(in: badLatitude), 0)
    }

    func testAbsurdZoomLevelsClampToTheSupportedCeilingInsteadOfOverflowing() {
        let region = ImmersiveMapOfflineRegion(id: "deep",
                                               southWest: GeoCoordinate(latitude: 51.5073, longitude: -0.1278),
                                               northEast: GeoCoordinate(latitude: 51.5074, longitude: -0.1277),
                                               zoomLevels: 0...64)
        // Counting must not trap; the deepest zoom actually covered is the
        // supported ceiling.
        XCTAssertGreaterThan(OfflineRegionTileMath.tileCount(in: region), 0)
        XCTAssertEqual(OfflineRegionTileMath.coverage(of: region).last?.zoom,
                       OfflineRegionTileMath.maximumSupportedZoomLevel)
    }

    func testZoomClampingDropsLevelsAboveProviderMaximum() {
        let region = ImmersiveMapOfflineRegion(id: "city",
                                               southWest: GeoCoordinate(latitude: 51, longitude: 0),
                                               northEast: GeoCoordinate(latitude: 52, longitude: 1),
                                               zoomLevels: 0...22)
        XCTAssertEqual(region.clampingZoomLevels(toMaximum: 14).zoomLevels, 0...14)
        XCTAssertEqual(region.clampingZoomLevels(toMaximum: nil).zoomLevels, 0...22)

        let deepRegion = ImmersiveMapOfflineRegion(id: "deep",
                                                   southWest: GeoCoordinate(latitude: 51, longitude: 0),
                                                   northEast: GeoCoordinate(latitude: 52, longitude: 1),
                                                   zoomLevels: 16...18)
        XCTAssertEqual(deepRegion.clampingZoomLevels(toMaximum: 14).zoomLevels, 14...14)
    }
}

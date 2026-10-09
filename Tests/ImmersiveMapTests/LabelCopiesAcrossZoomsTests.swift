// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The same feature parsed from tiles of two zooms, as a coarse tile
/// standing in brings it beside the exact one: the copies share their key,
/// the zoom they show from and their ranks, so the working set can keep
/// one copy of a key and drop the others without changing which feature
/// shows or when.
final class LabelCopiesAcrossZoomsTests: XCTestCase {
    private static let latitude = 40.7124
    private static let longitude = -74.0081

    private func parseLabels(z: Int, features: (_ point: (Int32, Int32)) -> [VectorTileFixture.Feature],
                             layerName: String) throws -> [ParsedTextLabel] {
        let tile = WebMercatorTileScheme.tile(latitude: Self.latitude, longitude: Self.longitude, z: z)
        let point = WebMercatorTileScheme.tileLocalPoint(latitude: Self.latitude, longitude: Self.longitude, in: tile)
        let data = VectorTileFixture.layersTile([(layerName: layerName, features: features(point))])
        let parser = TileMvtParser.forTests(settings: .default, mapStyle: ProtomapsBasemapDefaultMapStyle())
        return try parser.parse(tile: tile, mvtData: data).textLabels
    }

    private func assertCopiesMatch(layerName: String,
                                   features: @escaping (_ point: (Int32, Int32)) -> [VectorTileFixture.Feature],
                                   file: StaticString = #filePath,
                                   line: UInt = #line) throws {
        let fine = try parseLabels(z: 15, features: features, layerName: layerName)
        let coarse = try parseLabels(z: 13, features: features, layerName: layerName)
        XCTAssertEqual(fine.count, 1, file: file, line: line)
        XCTAssertEqual(coarse.count, 1, file: file, line: line)
        guard let fine = fine.first, let coarse = coarse.first else {
            return
        }
        XCTAssertEqual(fine.key, coarse.key, "One feature, one key in every tile", file: file, line: line)
        XCTAssertEqual(fine.minCameraZoom, coarse.minCameraZoom, file: file, line: line)
        XCTAssertEqual(fine.collisionPriority, coarse.collisionPriority, file: file, line: line)
        XCTAssertEqual(fine.sortKey, coarse.sortKey, file: file, line: line)
        XCTAssertEqual(fine.text, coarse.text, file: file, line: line)
    }

    func testAPoiCopyFromACoarserTileMatchesTheExactOne() throws {
        try assertCopiesMatch(layerName: "pois") { point in
            [.poi(id: 41, at: point, kind: "attraction", name: "Woolworth Building", minZoom: 14,
                  extra: ["sort_rank": "120"])]
        }
    }

    func testAShopCopyWaitingForItsCategoryZoomMatchesTheExactOne() throws {
        try assertCopiesMatch(layerName: "pois") { point in
            [.poi(id: 42, at: point, kind: "hotel", name: "M Social Hotel New York Downtown", minZoom: 15)]
        }
    }

    func testAPlaceCopyFromACoarserTileMatchesTheExactOne() throws {
        try assertCopiesMatch(layerName: "places") { point in
            [.place(id: 43, at: point, kind: "locality", kindDetail: "city", name: "New York", populationRank: 16)]
        }
    }
}

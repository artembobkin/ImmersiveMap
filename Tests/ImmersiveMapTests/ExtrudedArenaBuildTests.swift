// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// A prepared tile with a real building mesh must survive the arena round
/// trip: plan, GPU materialize from the parse path, and materialize again
/// from the disk-cached arena image. The empty-extruded fixtures the other
/// suites use skip these spans entirely, which is how a stride mismatch in
/// the building vertex once reached a live map before any test saw it.
final class ExtrudedArenaBuildTests: XCTestCase {
    func testTileWithBuildingsMaterializesFromParseAndFromArenaImage() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable in this test environment")
        }
        let tile = Tile(x: 1, y: 2, z: 15)
        let prepared = Self.preparedTileWithBuilding(tile: tile)
        let factory = MetalTileFactory(metalDevice: device)

        let plan = TileArenaImageMath.plan(for: prepared)
        XCTAssertNotNil(factory.makeTile(from: prepared, plan: plan),
                        "The parse path must rebuild buffers from the plan's span table")

        let identity = PreparedTileCacheIdentity(preparedFormatVersion: PreparedTileDiskCaching.preparedFormatVersion,
                                                 styleRevision: 1,
                                                 tileSourceRevision: 2,
                                                 flatSeparateRoadRenderingMinimumZoom: 8,
                                                 textRevision: 1,
                                                 labelLanguage: .english,
                                                 labelFallbackPolicy: .international,
                                                 houseNumbersEnabled: true,
                                                 houseNumbersMinimumZoom: 15,
                                                 capitalMaximumZoom: 12,
                                                 cityMaximumZoom: 12,
                                                 smallSettlementMaximumZoom: 12,
                                                 landmarkMinimumZoom: 15,
                                                 addTestBorders: false)
        let encoded = try PreparedTileDiskCodec.encode(preparedTile: prepared,
                                                       cacheIdentity: identity,
                                                       sourceETag: "etag",
                                                       compressionEnabled: true,
                                                       blobTransport: .inline,
                                                       plan: plan)
        let image = try PreparedTileDiskCodec.decode(data: encoded.metadata,
                                                     expectedTile: tile,
                                                     cacheIdentity: identity,
                                                     expectedSourceETag: nil,
                                                     blobFileURL: URL(fileURLWithPath: "/dev/null")).image
        let outcome = await factory.makeTile(fromImage: image)
        guard case .tile = outcome else {
            XCTFail("The disk path must rebuild buffers from the cached span table, got \(outcome)")
            return
        }
    }

    /// One ground triangle plus one extruded building triangle with a style,
    /// so both the flat and the building spans are non-empty.
    private static func preparedTileWithBuilding(tile: Tile) -> PreparedTileCPU {
        let base = PreparedTileCPUTestFixtures.withGroundTriangle(tile: tile)
        let extruded = PreparedTileCPU.Extruded(
            vertices: [
                TileMvtParser.ExtrudedVertexIn(position: SIMD3<Float>(100, 200, 0),
                                               normal: SIMD3<Float>(0, -1, 0),
                                               styleIndex: 0),
                TileMvtParser.ExtrudedVertexIn(position: SIMD3<Float>(300, 200, 0),
                                               normal: SIMD3<Float>(0, -1, 0),
                                               styleIndex: 0),
                TileMvtParser.ExtrudedVertexIn(position: SIMD3<Float>(300, 200, 55.5),
                                               normal: SIMD3<Float>(0, -1, 0),
                                               styleIndex: 0)
            ],
            indices: [0, 1, 2],
            styles: [TilePolygonStyle(color: SIMD4<Float>(0.8, 0.8, 0.8, 1))]
        )
        return PreparedTileCPU(tile: tile,
                               ground: base.ground,
                               roads: base.roads,
                               bridgeOverlay: base.bridgeOverlay,
                               extruded: extruded,
                               textLabels: base.textLabels,
                               roadLabels: base.roadLabels)
    }
}

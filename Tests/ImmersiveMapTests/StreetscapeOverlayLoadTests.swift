// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
@testable import ImmersiveMap
import Mvt
import XCTest

/// The streetscape over loopback: at street zoom a tile is two requests,
/// the map tile and the streetscape tile, merged into one before parsing.
final class StreetscapeOverlayLoadTests: XCTestCase {
    private let tile = Tile(x: 39615, y: 20486, z: 16)

    private func makeParser(_ settings: ImmersiveMapSettings) -> TileMvtParser {
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: settings)
        return TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                             labelProviderProfile: runtimeContext.labelProviderProfile,
                             config: settings,
                             glyphCoverage: .legacyAtlasForTests)
    }

    private var street: VectorTileFixture.Feature {
        .init(id: 2,
              geometry: .line(points: [(1200, 1050), (2900, 1050)]),
              properties: ["class": "primary", "lanes": "4", "lanes_src": "tagged", "name": "Tverskaya Street"])
    }

    private var surface: VectorTileFixture.Feature {
        .init(id: 1,
              geometry: .polygon(ring: [(1800, 800), (2600, 800), (2600, 1300), (1800, 1300)]),
              properties: ["class": "primary", "subclass": "carriageway_area", "origin": "graph"])
    }

    private var dividingLine: VectorTileFixture.Feature {
        .init(id: 3,
              geometry: .line(points: [(1850, 1050), (2550, 1050)]),
              properties: ["marking": "dividing", "style": "dashed", "paint": "white"])
    }

    private static let fixtureETag = "\"immersive-map-test-fixture\""


    /// The merged tile comes back only where the archive answers, so both
    /// responses are decoded as one tile. The MVT decoder appends every layer
    /// it meets in the buffer: this is the property the merge relies on.
    func testTwoConcatenatedTilesDecodeAsOne() throws {
        let map = VectorTileFixture.layerTile(layerName: "transportation", features: [street])
        let overlay = VectorTileFixture.layerTile(layerName: "streetscape", features: [surface, dividingLine])
        let decoded = try MvtTileDecoder.decode(data: map + overlay)
        XCTAssertEqual(decoded.layers.map(\.name), ["transportation", "streetscape"])
        XCTAssertEqual(decoded.layers.map(\.features.count), [1, 2])
    }

    func testAtStreetZoomATileIsTwoRequestsMergedIntoOne() async throws {
        let map = VectorTileFixture.layerTile(layerName: "transportation", features: [street])
        let overlay = VectorTileFixture.layerTile(layerName: "streetscape", features: [surface, dividingLine])
        let server = try LocalTileServer(route: { path in
            if path.hasPrefix("/streetscape/") {
                return path.hasPrefix("/streetscape/16/") ? .protobuf(overlay) : nil
            }
            return path.hasPrefix("/tiles/") ? .protobuf(map) : nil
        })
        let base = try XCTUnwrap(server.baseURL).absoluteString
        let settings = FixtureTiles.settings()
            .tileURLTemplate("\(base)/tiles/{z}/{x}/{y}.mvt")
            .streetscapeTileURLTemplate("\(base)/streetscape/{z}/{x}/{y}.mvt")
            .streetscape(isEnabled: true)
        let downloader = TileDownloader(config: settings)
        XCTAssertTrue(downloader.requestsStreetscape)
        let pipeline = DefaultTileLoadPipeline(tileRenderStore: nil,
                                               preparedTileDiskCaching: nil,
                                               tileDownloader: downloader,
                                               offlineTileStore: nil,
                                               offlineMode: .disabled,
                                               streetscape: settings.tiles.streetscape)

        let merged = await pipeline.download(tile: tile)
        XCTAssertEqual(merged, .success(map + overlay, etag: Self.fixtureETag + "|" + Self.fixtureETag))

        let coarse = await pipeline.download(tile: Tile(x: 9903, y: 5121, z: 14))
        XCTAssertEqual(coarse, .success(map, etag: Self.fixtureETag),
                       "Below the archive's zoom a tile is one request, ETag untouched")

        let uncovered = await pipeline.download(tile: Tile(x: 19807, y: 10243, z: 15))
        XCTAssertEqual(uncovered, .success(map, etag: Self.fixtureETag + "|-"),
                       "Where the archive has no tile the map tile stands alone")

        guard case let .success(bytes, _) = merged else {
            return XCTFail("The merged download failed")
        }
        let parsed = try makeParser(settings).parse(tile: tile, mvtData: bytes).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(parsed.detail.drawing.indices.count, 0, "The measured paint draws")
    }

    func testWithTheStreetscapeOffATileIsOneRequest() async throws {
        let map = VectorTileFixture.layerTile(layerName: "transportation", features: [street])
        let streetscapeRequests = Locked(0)
        let server = try LocalTileServer(route: { path in
            if path.hasPrefix("/streetscape/") {
                streetscapeRequests.withLock { $0 += 1 }
                return nil
            }
            return .protobuf(map)
        })
        let base = try XCTUnwrap(server.baseURL).absoluteString
        let settings = FixtureTiles.settings()
            .tileURLTemplate("\(base)/tiles/{z}/{x}/{y}.mvt")
            .streetscapeTileURLTemplate("\(base)/streetscape/{z}/{x}/{y}.mvt")
        let downloader = TileDownloader(config: settings)
        XCTAssertFalse(downloader.requestsStreetscape)
        let pipeline = DefaultTileLoadPipeline(tileRenderStore: nil,
                                               preparedTileDiskCaching: nil,
                                               tileDownloader: downloader,
                                               offlineTileStore: nil,
                                               offlineMode: .disabled,
                                               streetscape: settings.tiles.streetscape)
        let result = await pipeline.download(tile: tile)
        XCTAssertEqual(result, .success(map, etag: Self.fixtureETag))
        XCTAssertEqual(streetscapeRequests.withLock { $0 }, 0)
    }
}

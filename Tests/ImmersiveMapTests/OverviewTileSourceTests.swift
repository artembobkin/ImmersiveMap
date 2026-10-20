// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap
import Mvt
import MvtTestSupport
import PMTiles
import PMTilesTestSupport

/// The overview of the globe laid into the map's tiles: the shipped archive
/// carries the biomes and the zoom 0 lakes at the overview zooms, the road
/// network at zooms 2 to 5, and nothing past them, and a map tile with the
/// overview appended decodes as one tile with both tiles' layers.
final class OverviewTileSourceTests: XCTestCase {
    private var baseDirectory: URL!

    override func setUpWithError() throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverviewTileSource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    func testBundledArchiveCarriesTheBiomesAndTheZoomZeroLakes() async throws {
        let source = try XCTUnwrap(OverviewTileSource.bundled(), "The package must ship the overview archive")

        let worldBytes = await source.tileBytes(Tile(x: 0, y: 0, z: 0))
        let world = try XCTUnwrap(worldBytes)
        let worldTile = try MvtTileDecoder.decode(data: world)
        let worldLayers = worldTile.layers
        let biomes = try XCTUnwrap(worldLayers.first { $0.name == "biome" })
        XCTAssertEqual(biomes.features.count, 14, "One feature per biome of RESOLVE Ecoregions 2017")
        let kinds = Set(biomes.features.compactMap { feature in
            Self.properties(of: feature, in: biomes, tile: worldTile)["kind"]?.stringValue
        })
        for kind in ["desert", "tundra", "boreal_forest", "tropical_moist_forest", "temperate_grassland"] {
            XCTAssertTrue(kinds.contains(kind), "z0 must carry \(kind)")
        }
        XCTAssertTrue(biomes.features.allSatisfy { $0.type == .polygon })
        let lakes = try XCTUnwrap(worldLayers.first { $0.name == "lake" })
        XCTAssertGreaterThan(lakes.features.count, 10, "The Natural Earth 1:110m lakes at z0")
        XCTAssertFalse(worldLayers.contains { $0.name == "road" }, "The globe tile carries no roads")

        // The road network from zoom 2: European Russia at z3 and the
        // Moscow region at z5 carry ranked lines, and z6 none, where the
        // basemap's trunks arrive.
        let russiaBytes = await source.tileBytes(Tile(x: 4, y: 2, z: 3))
        let russia = try MvtTileDecoder.decode(data: try XCTUnwrap(russiaBytes))
        let roads = try XCTUnwrap(russia.layers.first { $0.name == "road" })
        XCTAssertGreaterThan(roads.features.count, 20)
        XCTAssertTrue(roads.features.allSatisfy { $0.type == .linestring })
        let ranks = Set(roads.features.compactMap { feature in
            Self.properties(of: feature, in: roads, tile: russia)["rank"]?.intValue
        })
        XCTAssertTrue(ranks.contains(3), "The continental routes are on the z3 tile")
        XCTAssertTrue(ranks.allSatisfy { (3...7).contains($0) })
        let moscowBytes = await source.tileBytes(Tile(x: 19, y: 10, z: 5))
        let moscowLayers = try MvtTileDecoder.decode(data: try XCTUnwrap(moscowBytes)).layers.map(\.name)
        XCTAssertTrue(moscowLayers.contains("road"))
        let moscowDeeperBytes = await source.tileBytes(Tile(x: 38, y: 20, z: 6))
        let moscowDeeperLayers = try MvtTileDecoder.decode(data: try XCTUnwrap(moscowDeeperBytes)).layers.map(\.name)
        XCTAssertFalse(moscowDeeperLayers.contains("road"), "Past zoom 5 the basemap's own roads draw")

        // Zoom 1 has the biomes alone, the Caspian and Baikal included: the
        // basemap ships its own lakes from there.
        let eurasiaBytes = await source.tileBytes(Tile(x: 1, y: 0, z: 1))
        let eurasia = try XCTUnwrap(eurasiaBytes)
        let eurasiaLayers = try MvtTileDecoder.decode(data: eurasia).layers.map(\.name)
        XCTAssertTrue(eurasiaLayers.contains("biome"))
        XCTAssertFalse(eurasiaLayers.contains("lake"))

        // The deepest tiles carry the biomes at the land cover's last zoom,
        // and past them there is nothing to lay in.
        let alpsBytes = await source.tileBytes(Tile(x: 67, y: 45, z: 7))
        let alps = try XCTUnwrap(alpsBytes)
        XCTAssertTrue(try MvtTileDecoder.decode(data: alps).layers.map(\.name).contains("biome"))
        let past = await source.tileBytes(Tile(x: 135, y: 90, z: 8))
        XCTAssertNil(past)
    }

    func testMergedTileDecodesWithBothTilesLayers() throws {
        let mapTile = MvtTileMessage(layers: [
            MvtLayerMessage(name: "earth",
                            features: [MvtFeatureMessage(type: .polygon, geometry: [9, 0, 0, 26, 20, 0, 0, 20, 15])]),
            MvtLayerMessage(name: "water",
                            features: [MvtFeatureMessage(type: .point, geometry: [9, 50, 50])])
        ]).serializedData()
        let overview = MvtTileMessage(layers: [
            MvtLayerMessage(name: "biome",
                            features: [MvtFeatureMessage(tags: [0, 0], type: .polygon, geometry: [9, 0, 0, 26, 20, 0, 0, 20, 15])],
                            keys: ["kind"],
                            values: [.string("desert")])
        ]).serializedData()

        let merged = try MvtTileDecoder.decode(data: OverviewTileSource.merge(mapTile: mapTile, overview: overview))
        XCTAssertEqual(merged.layers.map(\.name), ["earth", "water", "biome"])
        let biome = try XCTUnwrap(merged.layers.last)
        XCTAssertEqual(biome.features.count, 1)
        XCTAssertEqual(Self.properties(of: biome.features[0], in: biome, tile: merged)["kind"]?.stringValue, "desert")
    }

    /// The feature's tags as a dictionary: the packed key and value indices
    /// into the layer's tables, in pairs.
    private static func properties(of feature: MvtDecodedFeature,
                                   in layer: MvtDecodedLayer,
                                   tile: MvtDecodedTile) -> [String: MvtValue] {
        let tags = feature.tags.materializedValues(data: tile.sourceData)
        var properties: [String: MvtValue] = [:]
        for index in stride(from: 0, to: tags.count - 1, by: 2) {
            properties[layer.keys[Int(tags[index])]] = layer.values[Int(tags[index + 1])]
        }
        return properties
    }

    /// The pipeline lays the overview into a downloaded tile the overview
    /// covers and leaves every other tile as the source sent it.
    func testPipelineLaysTheOverviewIntoTheTilesItCovers() async throws {
        let covered = Tile(x: 0, y: 0, z: 0)
        let uncovered = Tile(x: 1, y: 1, z: 1)
        let overviewBytes = MvtTileMessage(layers: [MvtLayerMessage(name: "biome")]).serializedData()
        var writer = PMTilesArchiveWriter()
        writer.minZoom = 0
        writer.maxZoom = 1
        writer.tiles = [PMTilesArchiveWriter.Tile(z: 0, x: 0, y: 0, data: overviewBytes)]
        let archiveURL = baseDirectory.appendingPathComponent("overview.pmtiles")
        try writer.serializedData().write(to: archiveURL)

        let mapBytes = MvtTileMessage(layers: [MvtLayerMessage(name: "earth")]).serializedData()
        let pipeline = DefaultTileLoadPipeline(tileRenderStore: nil,
                                               preparedTileDiskCaching: nil,
                                               tileDownloader: ScriptedTileDownloader(result: .success(mapBytes, etag: "\"planet\"")),
                                               offlineTileStore: nil,
                                               offlineMode: .disabled,
                                               overviewTileSource: OverviewTileSource(archiveURL: archiveURL))

        let laid = await pipeline.download(tile: covered)
        guard case let .success(laidBytes, laidETag) = laid else {
            return XCTFail("Expected the tile with the overview laid in, got \(laid)")
        }
        XCTAssertEqual(laidETag, "\"planet\"", "The source's ETag travels on")
        XCTAssertEqual(try MvtTileDecoder.decode(data: laidBytes).layers.map(\.name), ["earth", "biome"])

        let untouched = await pipeline.download(tile: uncovered)
        XCTAssertEqual(untouched, .success(mapBytes, etag: "\"planet\""))
    }

    private final class ScriptedTileDownloader: TileDownloader {
        let result: DownloadResult

        init(result: DownloadResult) {
            self.result = result
            super.init(archive: PMTilesArchiveClient(archiveURL: FixtureTiles.deadEndArchiveURL,
                                                     requestHeaders: [:],
                                                     session: URLSession(configuration: .ephemeral)))
        }

        override func downloadResult(tile: Tile) async -> DownloadResult {
            result
        }
    }
}

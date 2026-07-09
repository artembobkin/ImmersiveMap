// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class NightLightsTileSetTests: XCTestCase {
    func testMetadataDecodesFromJSON() throws {
        let json = """
        {
            "version": 1,
            "format": "jpg",
            "tileSize": 1024,
            "minZoom": 4,
            "maxZoom": 6,
            "source": "NASA Black Marble 2016",
            "attribution": "NASA Earth Observatory",
            "tileURLTemplate": "http://localhost:9000/night-lights/v1/tiles/night_lights_{z}_{x}_{y}.jpg"
        }
        """

        let metadata = try JSONDecoder().decode(NightLightsTileSet.Metadata.self, from: Data(json.utf8))

        XCTAssertEqual(metadata.version, 1)
        XCTAssertEqual(metadata.format, "jpg")
        XCTAssertEqual(metadata.tileSize, 1024)
        XCTAssertEqual(metadata.minZoom, 4)
        XCTAssertEqual(metadata.maxZoom, 6)
        XCTAssertEqual(metadata.source, "NASA Black Marble 2016")
        XCTAssertEqual(metadata.attribution, "NASA Earth Observatory")
        XCTAssertEqual(metadata.tileURLTemplate,
                       "http://localhost:9000/night-lights/v1/tiles/night_lights_{z}_{x}_{y}.jpg")
    }

    func testBestAvailableTileClampsZoomToMetadataRange() {
        let tileSet = makeTileSet()

        XCTAssertEqual(tileSet.bestAvailableTile(for: Tile(x: 1, y: 1, z: 2)),
                       Tile(x: 4, y: 4, z: 4))
        XCTAssertEqual(tileSet.bestAvailableTile(for: Tile(x: 25, y: 35, z: 6)),
                       Tile(x: 25, y: 35, z: 6))
        XCTAssertEqual(tileSet.bestAvailableTile(for: Tile(x: 101, y: 142, z: 8)),
                       Tile(x: 25, y: 35, z: 6))
    }

    func testMappingReturnsNilWhenRequestedZoomIsBelowMinimumZoom() {
        let tileSet = makeTileSet()

        XCTAssertNil(tileSet.mapping(for: Tile(x: 1, y: 1, z: 2)))
    }

    func testMappingReturnsSourceTileAndRelativeUVsForLowerZoomSource() throws {
        let tileSet = makeTileSet()

        let mapping = try XCTUnwrap(tileSet.mapping(for: Tile(x: 101, y: 142, z: 8)))

        XCTAssertEqual(mapping.tile, Tile(x: 25, y: 35, z: 6))
        XCTAssertEqual(mapping.uvOrigin.x, Float(0.25), accuracy: Float(0.0001))
        XCTAssertEqual(mapping.uvOrigin.y, Float(0.50), accuracy: Float(0.0001))
        XCTAssertEqual(mapping.uvScale.x, Float(0.25), accuracy: Float(0.0001))
        XCTAssertEqual(mapping.uvScale.y, Float(0.25), accuracy: Float(0.0001))
    }

    func testMetadataLoaderBuildsTileSetFromManifestDataAsynchronously() async throws {
        let metadataURL = URL(string: "https://example.com/night-lights/v1/night_lights_manifest.json")!
        let loader = NightLightsTileSetMetadataLoader { requestedURL in
            XCTAssertEqual(requestedURL, metadataURL)
            return Data(self.metadataJSON.utf8)
        }

        let tileSet = try await loader.load(from: metadataURL)

        XCTAssertEqual(tileSet.metadata, makeRemoteMetadata())
    }

    func testURLResolvesRemoteTileTemplateFromMetadata() throws {
        let tileSet = NightLightsTileSet(
            metadata: NightLightsTileSet.Metadata(
                version: 1,
                format: "jpg",
                tileSize: 1024,
                minZoom: 4,
                maxZoom: 6,
                source: "NASA Black Marble 2016",
                attribution: "NASA Earth Observatory",
                tileURLTemplate: "http://localhost:9000/night-lights/v1/tiles/night_lights_{z}_{x}_{y}.jpg"
            )
        )

        let url = try XCTUnwrap(tileSet.url(for: Tile(x: 101, y: 142, z: 8)))

        XCTAssertEqual(url.absoluteString,
                       "http://localhost:9000/night-lights/v1/tiles/night_lights_6_25_35.jpg")
    }

    func testURLReturnsNilWhenMetadataHasNoRemoteTileTemplate() {
        let tileSet = NightLightsTileSet(metadata: makeMetadata())

        XCTAssertNil(tileSet.url(for: Tile(x: 101, y: 142, z: 8)))
    }

    private func makeTileSet() -> NightLightsTileSet {
        NightLightsTileSet(metadata: makeRemoteMetadata())
    }

    private func makeMetadata() -> NightLightsTileSet.Metadata {
        NightLightsTileSet.Metadata(version: 1,
                                    format: "jpg",
                                    tileSize: 1024,
                                    minZoom: 4,
                                    maxZoom: 6,
                                    source: "NASA Black Marble 2016",
                                    attribution: "NASA Earth Observatory",
                                    tileURLTemplate: nil)
    }

    private func makeRemoteMetadata() -> NightLightsTileSet.Metadata {
        NightLightsTileSet.Metadata(version: 1,
                                    format: "jpg",
                                    tileSize: 1024,
                                    minZoom: 4,
                                    maxZoom: 6,
                                    source: "NASA Black Marble 2016",
                                    attribution: "NASA Earth Observatory",
                                    tileURLTemplate: "http://localhost:9000/night-lights/v1/tiles/night_lights_{z}_{x}_{y}.jpg")
    }

    private var metadataJSON: String {
        """
        {
            "version": 1,
            "format": "jpg",
            "tileSize": 1024,
            "minZoom": 4,
            "maxZoom": 6,
            "source": "NASA Black Marble 2016",
            "attribution": "NASA Earth Observatory",
            "tileURLTemplate": "http://localhost:9000/night-lights/v1/tiles/night_lights_{z}_{x}_{y}.jpg"
        }
        """
    }
}

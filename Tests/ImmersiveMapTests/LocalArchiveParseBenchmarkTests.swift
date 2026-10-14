// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt
import PMTiles
import TileFlattening
import XCTest
@testable import ImmersiveMap

/// A manual benchmark, not part of the suite: parses tiles out of a local
/// copy of the tile archive (`LocalTiles/<planet date>.pmtiles` in the
/// repository root, the dev app's) with and without the ground relief,
/// and prints where the time goes: the layers' reading, the flattening
/// whole, and the flattener's stages. Skips unless
/// `IMMERSIVEMAP_LOCAL_TILES_BENCH=1` is set and the archive is there.
/// Needs no Metal, so `swift test --filter LocalArchiveParseBenchmarkTests`
/// runs it.
final class LocalArchiveParseBenchmarkTests: XCTestCase {
    func testParseTimesOfLocalTiles() async throws {
        guard ProcessInfo.processInfo.environment["IMMERSIVEMAP_LOCAL_TILES_BENCH"] == "1" else {
            throw XCTSkip("Opt-in benchmark: set IMMERSIVEMAP_LOCAL_TILES_BENCH=1 to run against the local archive")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let archives = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("LocalTiles"),
                                                                   includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pmtiles" }
        guard let archiveURL = archives.first else {
            throw XCTSkip("No local archive under LocalTiles/")
        }
        let client = PMTilesArchiveClient(archiveURL: archiveURL,
                                          requestHeaders: [:],
                                          session: URLSession(configuration: TileDownloader.makeSessionConfiguration()))
        let tiles = [Tile(x: 16, y: 11, z: 5), Tile(x: 16, y: 10, z: 5), Tile(x: 66, y: 45, z: 7),
                     Tile(x: 531, y: 364, z: 10), Tile(x: 2127, y: 1457, z: 12)]
        let withRelief = ImmersiveMapSettings.default.groundRelief(isEnabled: true)
        let withoutRelief = ImmersiveMapSettings.default
        for tile in tiles {
            guard case .tile(let data, _) = try await client.tileBytes(z: tile.z, x: tile.x, y: tile.y) else {
                print("z\(tile.z)/\(tile.x)/\(tile.y): no tile")
                continue
            }
            print("=== z\(tile.z)/\(tile.x)/\(tile.y): \(data.count) bytes")
            for (label, settings) in [("relief off", withoutRelief), ("relief on", withRelief)] {
                let parser = TileMvtParser.forTests(settings: settings)
                let options = TileParseOptions(settings: settings)
                let start = ContinuousClock.now
                let parsed = try parser.parse(tile: tile, mvtData: data)
                let total = ContinuousClock.now - start
                let layers = parsed.parseLayerTimings.sorted { $0.duration > $1.duration }.prefix(4)
                    .map { "\($0.layerName) \(Self.ms($0.duration))" }.joined(separator: ", ")
                print("\(label): parse \(Self.ms(total)) grid \(options.groundFlatteningGrid(forTileZoom: tile.z))"
                      + " flattened \(parsed.groundIsFlattened), top layers: \(layers)")
            }
            // The flattening on its own: the reading stage's fills, then the
            // flattener's stages.
            let parser = TileMvtParser.forTests(settings: withRelief)
            let decoded = try MvtTileDecoder.decode(data: data)
            let readStart = ContinuousClock.now
            let reading = parser.readingStage(decodedTile: decoded, tile: tile)
            let readTime = ContinuousClock.now - readStart
            var triangles = 0
            var polygons = 0
            var outlinePoints = 0
            for polygonsOfStyle in reading.polygonByStyle.values {
                for polygon in polygonsOfStyle where polygon.isLineRibbon == false {
                    polygons += 1
                    triangles += polygon.indices.count / 3
                    if polygon.isOutline { outlinePoints += polygon.vertices.count }
                }
            }
            let grid = TileParseOptions(settings: withRelief).groundFlatteningGrid(forTileZoom: tile.z)
            let flattenStart = ContinuousClock.now
            let flattened = GroundFlattening.flatten(polygonByStyle: reading.polygonByStyle, grid: grid)
            let flattenTime = ContinuousClock.now - flattenStart
            let outTriangles = flattened.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.indices.count / 3 } }
            print("reading \(Self.ms(readTime)), fills \(polygons) polygons, \(outlinePoints) outline points"
                  + " + \(triangles) triangles -> flatten \(Self.ms(flattenTime)) on grid \(grid): \(outTriangles) triangles")
            // The flattener's stages, the input built as GroundFlattening builds it.
            var input = FlattenInput()
            for style in reading.polygonByStyle.keys.sorted() {
                let fills = (reading.polygonByStyle[style] ?? []).filter { $0.isLineRibbon == false }
                guard fills.isEmpty == false else { continue }
                let paint = input.addPaint(FlatColor(r: style, g: 0, b: 0, a: 255))
                for polygon in fills {
                    GroundFlattening.addRings(of: polygon, paint: paint, to: &input)
                }
            }
            for cells in [16, 32, 64, 128, 256] {
                var flattenOptions = FlattenOptions()
                flattenOptions.maxX = GroundFlattening.tileExtent
                flattenOptions.maxY = GroundFlattening.tileExtent
                flattenOptions.columns = cells
                flattenOptions.rows = cells
                var timings = FlattenTimings()
                let mesh = Flattener.flatten(input, options: flattenOptions, timings: &timings)
                print("grid \(cells): binning \(Self.ms(timings.binning)) sweep \(Self.ms(timings.sweep))"
                      + " triangulation \(Self.ms(timings.triangulation)) merge \(Self.ms(timings.merge))"
                      + " -> \(mesh.indices.count / 3) triangles")
            }
        }
    }

    private static func ms(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
        return ms(seconds)
    }

    private static func ms(_ seconds: Double) -> String {
        String(format: "%.0fms", seconds * 1000)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
#if canImport(MvtTestSupport)
import MvtTestSupport
#endif
import XCTest

/// Wall-clock benchmark for the tile parse pipeline on a dense synthetic city
/// tile. It never fails on timing: it prints numbers and asserts only that the
/// synthetic tile actually exercises every parse path (polygons, extrusions,
/// separate roads, point and road labels). Run optimized for real numbers
/// (the `-DDEBUG` keeps the test-only hooks the suite compiles against):
///
///     swift test -c release -Xswiftc -DDEBUG --filter TileMvtParserPerformanceTests
final class TileMvtParserPerformanceTests: XCTestCase {
    func testParseDenseCityTileThroughput() throws {
        let tile = Tile(x: 39_167, y: 21_090, z: 16)
        let mvtData = MvtFixtureTileMessages.denseCity().serializedData()

        let config = ImmersiveMapSettings.default
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        let parser = TileMvtParser(
            determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
            labelProviderProfile: runtimeContext.labelProviderProfile,
            config: config,
            glyphCoverage: .legacyAtlasForTests
        )

        // The benchmark is only meaningful if the tile drives every stage.
        let parsed = try parser.parse(tile: tile, mvtData: mvtData)
        XCTAssertGreaterThan(parsed.drawingPolygon.indices.count, 0, "ground polygons missing")
        XCTAssertGreaterThan(parsed.drawingExtruded.indices.count, 0, "building extrusions missing")
        // The automobile network draws in its own tier above the pedestrian
        // one; a city tile has both.
        let roadIndexCount = parsed.drawingRoadPhases.automobileGround.casing.drawing.indices.count
            + parsed.drawingRoadPhases.automobileGround.fill.drawing.indices.count
            + parsed.drawingRoadPhases.ground.fill.drawing.indices.count
        XCTAssertGreaterThan(roadIndexCount, 0, "separate-road geometry missing")
        XCTAssertGreaterThan(parsed.textLabels.count, 0, "point labels missing")
        XCTAssertGreaterThan(parsed.roadTextLabels.count, 0, "road labels missing")

        let fullParse = try Self.measure(warmup: 2, iterations: 10) {
            _ = try parser.parse(tile: tile, mvtData: mvtData)
        }
        let wireDecode = try Self.measure(warmup: 2, iterations: 10) {
            _ = try MvtTileDecoder.decode(data: mvtData)
        }

        print("[perf] tile payload: \(mvtData.count) bytes")
        print("[perf] parse(full)    min \(Self.format(fullParse.min))  median \(Self.format(fullParse.median))")
        print("[perf] decode(wire)   min \(Self.format(wireDecode.min))  median \(Self.format(wireDecode.median))")
    }

    func testParseOceanOverviewTileThroughput() throws {
        let tile = Tile(x: 9, y: 5, z: 4)
        let mvtData = MvtFixtureTileMessages.oceanOverview().serializedData()

        let config = ImmersiveMapSettings.default
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        let parser = TileMvtParser(
            determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
            labelProviderProfile: runtimeContext.labelProviderProfile,
            config: config,
            glyphCoverage: .legacyAtlasForTests
        )

        let parsed = try parser.parse(tile: tile, mvtData: mvtData)
        XCTAssertGreaterThan(parsed.drawingPolygon.indices.count, 0, "overview polygons missing")

        let fullParse = try Self.measure(warmup: 2, iterations: 10) {
            _ = try parser.parse(tile: tile, mvtData: mvtData)
        }
        print("[perf] overview payload: \(mvtData.count) bytes")
        print("[perf] parse(overview)  min \(Self.format(fullParse.min))  median \(Self.format(fullParse.median))")
    }

    // MARK: - Timing

    private struct Timings {
        let min: TimeInterval
        let median: TimeInterval
    }

    private static func measure(warmup: Int,
                                iterations: Int,
                                _ body: () throws -> Void) rethrows -> Timings {
        for _ in 0..<warmup {
            try body()
        }
        var samples: [TimeInterval] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            samples.append(TimeInterval(elapsed) / 1_000_000_000.0)
        }
        samples.sort()
        return Timings(min: samples[0], median: samples[samples.count / 2])
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.2f ms", seconds * 1000.0)
    }
}

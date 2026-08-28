// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The cap edge strip: how the caps find the rim colour under them and how
/// a tile's polar band lands in the strip. The CPU side of what the cap
/// shader and the bake do.
final class GlobeCapStripSamplerTests: XCTestCase {
    func testLongitudeAngleWrapsIntoOneTurn() {
        XCTAssertEqual(GlobeCapStripSampler.u(theta: 0), 0)
        XCTAssertEqual(GlobeCapStripSampler.u(theta: .pi), 0.5, accuracy: 1e-6)
        XCTAssertEqual(GlobeCapStripSampler.u(theta: 2 * .pi), 0, accuracy: 1e-6)
        XCTAssertEqual(GlobeCapStripSampler.u(theta: -.pi / 2), 0.75, accuracy: 1e-6)
        XCTAssertEqual(GlobeCapStripSampler.u(theta: 5 * .pi), 0.5, accuracy: 1e-5)
    }

    func testLodFollowsTheStripDensityOnScreen() {
        // One strip texel per pixel: level 0.
        let texelRadians = 2 * Float.pi / Float(GlobeCapStripSampler.width)
        XCTAssertEqual(GlobeCapStripSampler.lod(radiansPerPixel: texelRadians), 0, accuracy: 1e-4)
        // Eight texels per pixel: level 3.
        XCTAssertEqual(GlobeCapStripSampler.lod(radiansPerPixel: 8 * texelRadians), 3, accuracy: 1e-4)
        // Magnified past level 0 and shrunk past the last level both clamp.
        XCTAssertEqual(GlobeCapStripSampler.lod(radiansPerPixel: texelRadians / 16), 0)
        XCTAssertEqual(GlobeCapStripSampler.lod(radiansPerPixel: 1e9), GlobeCapStripSampler.maximumLod)
        XCTAssertEqual(GlobeCapStripSampler.lod(radiansPerPixel: 0), 0)
    }

    func testMipChainReachesOneTexel() {
        XCTAssertEqual(1 << (GlobeCapStripSampler.mipLevelCount - 1), GlobeCapStripSampler.width)
        XCTAssertEqual(Int(GlobeCapStripSampler.maximumLod), GlobeCapStripSampler.mipLevelCount - 1)
    }

    func testPoleMeanLevelAveragesOneTileOfTheRim() {
        // At zoom z a tile owns width / 2^z texels: the level whose texel is
        // that wide is 12 - z.
        XCTAssertEqual(GlobeCapStripSampler.poleMeanLod(tileZoom: 0), 12)
        XCTAssertEqual(GlobeCapStripSampler.poleMeanLod(tileZoom: 3), 9)
        XCTAssertEqual(GlobeCapStripSampler.poleMeanLod(tileZoom: 12), 0)
        XCTAssertEqual(GlobeCapStripSampler.poleMeanLod(tileZoom: 20), 0)
    }

    func testPoleRowsAreTheFirstAndLastTileRows() {
        XCTAssertTrue(GlobeCapStripSampler.isPoleRow(Tile(x: 0, y: 0, z: 0), pole: .north))
        XCTAssertTrue(GlobeCapStripSampler.isPoleRow(Tile(x: 0, y: 0, z: 0), pole: .south))
        XCTAssertTrue(GlobeCapStripSampler.isPoleRow(Tile(x: 5, y: 0, z: 3), pole: .north))
        XCTAssertFalse(GlobeCapStripSampler.isPoleRow(Tile(x: 5, y: 0, z: 3), pole: .south))
        XCTAssertTrue(GlobeCapStripSampler.isPoleRow(Tile(x: 5, y: 7, z: 3), pole: .south))
        XCTAssertFalse(GlobeCapStripSampler.isPoleRow(Tile(x: 5, y: 3, z: 3), pole: .north))
    }

    func testBakeLaysTheSourceTilesPolarBandAcrossTheStrip() {
        let band = GlobeCapStripSampler.bandUnits
        // North: the tile's top rows (render space y up, edge at 4096) map to
        // y 0..1; x runs across the tile's share of the turn.
        let north = GlobeCapEdgeStrip.modelMatrix(source: Tile(x: 1, y: 0, z: 1), pole: .north)
        let edge = north * SIMD4<Float>(4096, 4096, 0, 1)
        XCTAssertEqual(edge.x, 4096, accuracy: 1e-3)
        XCTAssertEqual(edge.y, 1, accuracy: 1e-5)
        let bandStart = north * SIMD4<Float>(0, 4096 - band, 0, 1)
        XCTAssertEqual(bandStart.x, 2048, accuracy: 1e-3)
        XCTAssertEqual(bandStart.y, 0, accuracy: 1e-5)
        // A row below the band leaves the strip's viewport.
        XCTAssertLessThan((north * SIMD4<Float>(0, 4096 - 2 * band, 0, 1)).y, 0)

        // South: the tile's bottom rows, edge at 0.
        let south = GlobeCapEdgeStrip.modelMatrix(source: Tile(x: 0, y: 1, z: 1), pole: .south)
        let southEdge = south * SIMD4<Float>(4096, 0, 0, 1)
        XCTAssertEqual(southEdge.x, 2048, accuracy: 1e-3)
        XCTAssertEqual(southEdge.y, 0, accuracy: 1e-5)
        XCTAssertEqual((south * SIMD4<Float>(0, band, 0, 1)).y, 1, accuracy: 1e-5)
        XCTAssertGreaterThan((south * SIMD4<Float>(0, 2 * band, 0, 1)).y, 1)

        // Zoom 0: the one tile spans the whole strip.
        let whole = GlobeCapEdgeStrip.modelMatrix(source: Tile(x: 0, y: 0, z: 0), pole: .north)
        XCTAssertEqual((whole * SIMD4<Float>(4096, 4096, 0, 1)).x, 4096, accuracy: 1e-3)
        XCTAssertEqual((whole * SIMD4<Float>(0, 4096, 0, 1)).x, 0, accuracy: 1e-3)
    }

    func testStripUniformLayoutMatchesTheShader() {
        XCTAssertEqual(MemoryLayout<GlobeCapStripUniform>.stride, 16)
        XCTAssertEqual(MemoryLayout<GlobeCapStripUniform>.offset(of: \.hasStrip), 0)
        XCTAssertEqual(MemoryLayout<GlobeCapStripUniform>.offset(of: \.poleMeanLod), 4)
        XCTAssertEqual(MemoryLayout<GlobeCapStripUniform>.offset(of: \.padding), 8)
        XCTAssertEqual(GlobeCapStripUniform(hasStrip: true, poleMeanLod: 9).hasStrip, 1)
        XCTAssertEqual(GlobeCapStripUniform(hasStrip: false, poleMeanLod: 9).hasStrip, 0)
    }
}

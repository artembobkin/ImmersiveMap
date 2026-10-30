// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import ImageIO
@testable import ImmersiveMap
@testable import ImmersiveMapDebug
import Metal
import UniformTypeIdentifiers
import XCTest

/// The occlusion of the sky computed from a terrain tile's heights
/// (`GroundReliefOcclusion`): nothing on a plain or a summit, most at the
/// floor of a hole, less with a shorter radius, and the store computes it
/// for every tile that lands and again when the style changes.
final class GroundReliefOcclusionTests: XCTestCase {
    /// A tile of `size` texels a side at `metres` everywhere, with the
    /// square from `blockFrom` to `blockTo` (exclusive) at `blockMetres`.
    private func halves(size: Int, metres: Float, block: (from: Int, to: Int)? = nil, blockMetres: Float = 0) -> [UInt16] {
        var result = [UInt16](repeating: Self.half(metres), count: size * size)
        if let block {
            for y in block.from ..< block.to {
                for x in block.from ..< block.to {
                    result[y * size + x] = Self.half(blockMetres)
                }
            }
        }
        return result
    }

    /// A half float's bits for a value in the terrain's range.
    private static func half(_ value: Float) -> UInt16 {
        guard value != 0 else { return 0 }
        let exponent = Int(log2(abs(value)).rounded(.down))
        let mantissa = UInt16(((abs(value) / pow(2, Float(exponent))) - 1) * 1024)
        let sign: UInt16 = value < 0 ? 0x8000 : 0
        return sign | UInt16(exponent + 15) << 10 | mantissa
    }

    func testTheHalfFloatHelperRoundTrips() {
        for value: Float in [0, 1, 100, 1000, 2047, 3000] {
            XCTAssertEqual(GroundReliefTile.float(halfBits: Self.half(value)), value, accuracy: max(1, value / 1024))
        }
    }

    func testTheKeyClampsAndAStyleOffComputesNothing() {
        let key = GroundReliefOcclusion.Key(radiusMetres: -5, directions: 1, resolution: 4)
        XCTAssertEqual(key.radiusMetres, 0)
        XCTAssertEqual(key.directions, 4)
        XCTAssertEqual(key.resolution, 16)
        XCTAssertFalse(key.computes, "No radius, nothing to look at")
        XCTAssertFalse(GroundReliefOcclusion.Key(style: .none).computes)
        let on = GroundReliefOcclusion.Key(style: ImmersiveMapTerrainOcclusion())
        XCTAssertEqual(on.resolution, 128)
        XCTAssertEqual(on.directions, 8)
        XCTAssertEqual(on.radiusMetres, 3000)
        XCTAssertTrue(on.computes)
    }

    func testATexelSpansTheTilesSideOverItsTexels() {
        let equator = GroundReliefOcclusion.metresPerTexel(tile: Tile(x: 0, y: 0, z: 0), size: 512)
        XCTAssertEqual(equator, 40_075_017 / 512, accuracy: 100, "The world's circumference over the texels at the equator")
        let zoom10 = GroundReliefOcclusion.metresPerTexel(tile: Tile(x: 301, y: 385, z: 10), size: 512)
        XCTAssertEqual(zoom10, 40_075_017 / 1024 / 512 * cos(41.2 * .pi / 180), accuracy: 1, "At the tile's own latitude")
    }

    func testTheStepsGrowOutToTheRadius() {
        let steps = GroundReliefOcclusion.steps(radiusTexels: 20)
        XCTAssertEqual(steps.first, 1)
        XCTAssertEqual(steps.prefix(5), [1, 2, 3, 4, 5], "Every texel near")
        XCTAssertLessThanOrEqual(steps.last!, 20)
        XCTAssertGreaterThan(steps.last!, 15)
        for index in 1 ..< steps.count {
            XCTAssertGreaterThan(steps[index], steps[index - 1])
        }
        XCTAssertTrue(GroundReliefOcclusion.steps(radiusTexels: 0.5).isEmpty)
    }

    func testAPlainAndASummitSeeTheWholeSky() {
        let key = GroundReliefOcclusion.Key(radiusMetres: 1000, directions: 8, resolution: 16)
        let plain = GroundReliefOcclusion.compute(halves: halves(size: 64, metres: 500), size: 64, metresPerTexel: 30, key: key)
        XCTAssertEqual(plain.count, 16 * 16)
        XCTAssertTrue(plain.allSatisfy { $0 == 0 }, "Level ground is open to the sky")
        // A plateau in the middle: its top is a summit, open to the sky.
        let plateau = GroundReliefOcclusion.compute(halves: halves(size: 64, metres: 0, block: (24, 40), blockMetres: 2000),
                                                    size: 64, metresPerTexel: 30, key: key)
        XCTAssertEqual(plateau[8 * 16 + 8], 0, "The top of the plateau sees the whole sky")
        XCTAssertGreaterThan(plateau[8 * 16 + 4], 50, "The foot of its wall loses the sky on the wall's side")
    }

    func testTheFloorOfAHoleIsOccludedAndTheRadiusBoundsTheLook() {
        let size = 64
        // A plain at 2000 m with a hole of 0 m in the middle, 16 texels across.
        let hole = halves(size: size, metres: 2000, block: (24, 40), blockMetres: 0)
        let wide = GroundReliefOcclusion.Key(radiusMetres: 3000, directions: 8, resolution: 16)
        let occluded = GroundReliefOcclusion.compute(halves: hole, size: size, metresPerTexel: 30, key: wide)
        let centre = occluded[8 * 16 + 8]
        XCTAssertGreaterThan(centre, 200, "Walls of 2000 m a few hundred metres away hide most of the sky")
        XCTAssertEqual(occluded[1 * 16 + 1], 0, "The plain far from the hole sees the whole sky")
        XCTAssertEqual(occluded[8 * 16 + 7], occluded[8 * 16 + 8], accuracy: 40, "About the same across the floor")
        // A radius shorter than the distance to the walls sees no wall.
        let narrow = GroundReliefOcclusion.Key(radiusMetres: 100, directions: 8, resolution: 16)
        let unseen = GroundReliefOcclusion.compute(halves: hole, size: size, metresPerTexel: 30, key: narrow)
        XCTAssertEqual(unseen[8 * 16 + 8], 0, "The walls are 240 m away, past the radius")
        // More directions, the same answer within the sampling.
        let many = GroundReliefOcclusion.Key(radiusMetres: 3000, directions: 32, resolution: 16)
        let smooth = GroundReliefOcclusion.compute(halves: hole, size: size, metresPerTexel: 30, key: many)
        XCTAssertEqual(Int(smooth[8 * 16 + 8]), Int(centre), accuracy: 30)
    }

    func testTheStyleDefaultsAndThePanelsPlanner() {
        let style = ImmersiveMapTerrainOcclusion()
        XCTAssertTrue(style.isEnabled)
        XCTAssertEqual(style.strength, 0.6)
        XCTAssertEqual(style.radiusMeters, 3000)
        XCTAssertEqual(ProtomapsBasemapTheme.default.terrainOcclusion, style)
        XCTAssertEqual(ProtomapsBasemapMapStyle.default.vectorTileStyle.terrainOcclusion, style, "The default style reads the theme's")
        XCTAssertFalse(ImmersiveMapTerrainOcclusion.none.isEnabled)
        for metres: Float in [100, 250, 1000, 3000, 20_000] {
            let back = DebugOverlayOcclusionPlanner.radiusMetres(sliderValue: DebugOverlayOcclusionPlanner.sliderValue(radiusMetres: metres))
            XCTAssertEqual(back, metres, accuracy: metres * 0.01, "The radius slider round-trips \(metres) m")
        }
        XCTAssertEqual(DebugOverlayOcclusionPlanner.directionsIndex(for: 8), 1)
        XCTAssertEqual(DebugOverlayOcclusionPlanner.directionsIndex(for: 7), 1, "Snapped to the nearest step")
        XCTAssertEqual(DebugOverlayOcclusionPlanner.resolutionIndex(for: 512), 3)
        XCTAssertEqual(DebugOverlayOcclusionPlanner.radiusTitle(2500), "Radius 2.5 km")
        XCTAssertEqual(DebugOverlayOcclusionPlanner.radiusTitle(400), "Radius 400 m")
        XCTAssertEqual(DebugOverlayPanelCategory.occlusion.title, "AO")
        XCTAssertTrue(DebugOverlayPanelCategory.occlusion.shows(.occlusion))
        XCTAssertFalse(DebugOverlayPanelCategory.shadows.shows(.occlusion), "A tab of its own")
    }

    /// The store computes a tile's occlusion as it lands, under the
    /// style's key, computes it again when the panel changes the key,
    /// and hands it out with the relief. A style off computes nothing.
    func testTheStoreComputesTheOcclusionOfEveryTileAndAgainOnAChange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("A Metal device is required for the relief textures.")
        }
        let image = try Self.png(size: 8, metres: 500)
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true, minimumSourceZoom: 12)
        let style = ImmersiveMapTerrainOcclusion(resolution: 32)
        let ground = makeTestRelief(device: device, settings: settings, occlusion: style, fetch: { _ in .image(image) })
        let tile = Tile(x: 4823, y: 6160, z: 13)
        ground.setBands([FlatRingBand(zoom: 13, distance: 1, tileCount: 9, terrainZoom: 13)])
        XCTAssertTrue(waitUntil { ground.store.request(tiles: [tile]); return ground.store.isResident(tile) })
        let relief = try XCTUnwrap(ground.frame.relief(for: tile, terrain: tile))
        let computed = try XCTUnwrap(relief.occlusion, "Computed as the tile landed")
        XCTAssertEqual(computed.width, 32)
        XCTAssertEqual(computed.pixelFormat, .r8Unorm)
        XCTAssertEqual(ground.frame.statusSnapshot().occlusionComputedCount, 1)
        XCTAssertEqual(ground.frame.occlusionUniform.x, 0.6, accuracy: 1e-6, "The style's strength, the relief risen")
        XCTAssertEqual(ground.frame.occlusionUniform.y, 0)

        // The panel's radius: computed again, at the new key.
        var dragged = style
        dragged.radiusMeters = 500
        dragged.resolution = 16
        ground.setOcclusion(dragged, debugView: true)
        XCTAssertNil(ground.frame.relief(for: tile, terrain: tile)?.occlusion, "The old occlusion is not handed out under the new key")
        XCTAssertTrue(waitUntil { ground.frame.relief(for: tile, terrain: tile)?.occlusion?.width == 16 })
        XCTAssertEqual(ground.frame.occlusionUniform.y, 1, "The view of the occlusion alone")

        // Off: nothing is computed, nothing darkens.
        // Spelt out: `.none` on the optional parameter would be nil, the style's.
        ground.setOcclusion(ImmersiveMapTerrainOcclusion.none, debugView: false)
        XCTAssertNil(ground.frame.relief(for: tile, terrain: tile)?.occlusion)
        XCTAssertEqual(ground.frame.occlusionUniform.x, 0)
        XCTAssertNotNil(ground.frame.occlusionFallbackTexture, "A draw samples one texel of none")
        // Back to the style's: computed once more.
        ground.setOcclusion(nil, debugView: false)
        XCTAssertTrue(waitUntil { ground.frame.relief(for: tile, terrain: tile)?.occlusion?.width == 32 })
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    /// A Terrarium PNG of level ground at `metres`.
    private static func png(size: Int, metres: Int) throws -> Data {
        let encoded = metres + 32768
        let pixel: [UInt8] = [UInt8(encoded >> 8), UInt8(encoded & 0xFF), 0, 255]
        var bytes: [UInt8] = []
        for _ in 0 ..< size * size {
            bytes += pixel
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

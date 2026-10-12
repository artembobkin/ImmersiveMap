// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// What a raster target draws while its texture is on its way: the ring
/// bands move to other zooms at every zoom crossing, and the textures the
/// last zoom's bands drew are still on the GPU.
final class RasterStandInPlannerTests: XCTestCase {
    /// The zoom-out over Aosta, as recorded: at zoom 12 the third ring was
    /// z10 and the far ring z8. At zoom 11 the third ring is z9, whose
    /// textures are not in yet, and the far ring z7. Without stand-ins the
    /// z9 band was a hole, and the far ring's few texels showed through it,
    /// smeared over the relief. With them the band draws the z10 textures
    /// it drew a moment ago, and the z8 one where those do not reach.
    func testAZoomOutDrawsTheLastZoomsTexturesInTheHole() throws {
        let device = try Self.device()
        let z9 = Tile(x: 265, y: 186, z: 9)
        let z10Children = [Tile(x: 530, y: 372, z: 10), Tile(x: 531, y: 372, z: 10)]
        let z8 = try XCTUnwrap(z9.findParentTile(atZoom: 8))
        let z7 = try XCTUnwrap(z9.findParentTile(atZoom: 7))
        var resident: RasterStandInPlanner.Resident = [:]
        for tile in z10Children {
            resident[tile] = (RasterTileKey(tile: tile, size: 512, fadeZoom: 12), try Self.texture(device))
        }
        resident[z8] = (RasterTileKey(tile: z8, size: 128, fadeZoom: 12), try Self.texture(device))
        resident[z7] = (RasterTileKey(tile: z7, size: 128, fadeZoom: 11), try Self.texture(device))

        let plan = RasterStandInPlanner.plan(forMissing: [VisibleTile(tile: z9)],
                                             resident: resident,
                                             floorZoom: 0)
        let placed = Set(plan.placements.map(\.placeIn.tile))
        XCTAssertEqual(placed, Set(z10Children + [z8]),
                       "The two z10 textures still in, whole, and the z8 one under the half they leave")
        XCTAssertFalse(placed.contains(z7), "The far ring's own tile is not a stand-in: the finer ancestor is")
        XCTAssertTrue(plan.uncovered.isEmpty, "The ancestor covers the half the descendants leave")
    }

    /// A target with no texture over it, neither a descendant's nor an
    /// ancestor's, or with descendants that leave a hole no ancestor
    /// fills, is uncovered: the vector placements draw its ground. The
    /// descendants are found at any depth, as the vector planner's are.
    func testATargetNoTextureCoversWholeIsUncovered() throws {
        let device = try Self.device()
        let z9 = Tile(x: 265, y: 186, z: 9)
        let other = Tile(x: 266, y: 186, z: 9)
        let grandchild = Tile(x: 530 * 2, y: 372 * 2, z: 11)
        var resident: RasterStandInPlanner.Resident = [:]
        resident[grandchild] = (RasterTileKey(tile: grandchild, size: 512, fadeZoom: 13), try Self.texture(device))

        let plan = RasterStandInPlanner.plan(forMissing: [VisibleTile(tile: z9), VisibleTile(tile: other)],
                                             resident: resident,
                                             floorZoom: 0)
        XCTAssertEqual(plan.placements.map(\.placeIn.tile), [grandchild], "Two levels down, still a stand-in")
        XCTAssertEqual(plan.placements.first?.slot.tile, z9)
        XCTAssertEqual(Set(plan.uncovered.map(\.tile)), [z9, other],
                       "The grandchild leaves a hole no ancestor fills, and the other target has nothing")

        let none = RasterStandInPlanner.plan(forMissing: [VisibleTile(tile: z9)], resident: [:], floorZoom: 0)
        XCTAssertEqual(none.uncovered.map(\.tile), [z9])
    }

    /// Descendants that cover the target whole leave no room for an
    /// ancestor, and a target whose own texture is in needs none.
    func testWholeDescendantsLeaveNoHoleForAnAncestor() throws {
        let device = try Self.device()
        let z9 = Tile(x: 265, y: 186, z: 9)
        let z8 = try XCTUnwrap(z9.findParentTile(atZoom: 8))
        var resident: RasterStandInPlanner.Resident = [:]
        for x in 530 ... 531 {
            for y in 372 ... 373 {
                let tile = Tile(x: x, y: y, z: 10)
                resident[tile] = (RasterTileKey(tile: tile, size: 512, fadeZoom: 12), try Self.texture(device))
            }
        }
        resident[z8] = (RasterTileKey(tile: z8, size: 128, fadeZoom: 12), try Self.texture(device))
        let plan = RasterStandInPlanner.plan(forMissing: [VisibleTile(tile: z9)],
                                             resident: resident,
                                             floorZoom: 0)
        XCTAssertEqual(plan.placements.count, 4)
        XCTAssertFalse(plan.placements.contains { $0.placeIn.tile == z8 })
        XCTAssertTrue(plan.uncovered.isEmpty)
    }

    /// A stand-in two targets share is placed once, a stand-in the relief
    /// cannot draw yet is passed over for the next, and nothing below the
    /// floor zoom stands in.
    func testAStandInIsPlacedOnceAndKeepsToTheFloor() throws {
        let device = try Self.device()
        let targets = [VisibleTile(x: 530, y: 372, z: 10), VisibleTile(x: 531, y: 372, z: 10)]
        let z9 = Tile(x: 265, y: 186, z: 9)
        let z8 = try XCTUnwrap(z9.findParentTile(atZoom: 8))
        var resident: RasterStandInPlanner.Resident = [:]
        resident[z9] = (RasterTileKey(tile: z9, size: 512, fadeZoom: 11), try Self.texture(device))
        resident[z8] = (RasterTileKey(tile: z8, size: 128, fadeZoom: 12), try Self.texture(device))

        let shared = RasterStandInPlanner.plan(forMissing: targets, resident: resident, floorZoom: 0)
        XCTAssertEqual(shared.placements.map(\.placeIn.tile), [z9], "Once for both targets")

        let passedOver = RasterStandInPlanner.plan(forMissing: targets, resident: resident, floorZoom: 0,
                                                   isPlaceable: { $0 != z9 })
        XCTAssertEqual(passedOver.placements.map(\.placeIn.tile), [z8], "The z9 texture cannot draw yet, so its parent does")

        let floored = RasterStandInPlanner.plan(forMissing: targets, resident: resident, floorZoom: 9)
        XCTAssertTrue(floored.placements.isEmpty, "Nothing at or below the floor zoom stands in")
        XCTAssertEqual(floored.uncovered, targets, "And both targets are left to the vector placements")
    }

    // MARK: - Helpers

    private static func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("A Metal device is required for the textures.")
        }
        return device
    }

    private static func texture(_ device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false)
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }
}

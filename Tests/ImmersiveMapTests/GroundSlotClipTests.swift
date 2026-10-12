// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The ground a placement draws on the relief: its slot, cut to its ring's
/// band, in the source tile's local units.
final class GroundSlotClipTests: XCTestCase {
    /// A world where a zoom 12 tile is 4096 units a side, looked at from
    /// the middle, with a near band of zoom 12 to one ring and a far band
    /// of zoom 11 to three.
    private static let targetZoom = 12
    private static let flatRenderState = FlatRenderState(pan: SIMD2<Double>(0, 0),
                                                         renderMapSize: 4096 * Double(1 << targetZoom))
    private static let rings = GroundSlotClip.Rings(targetZoom: targetZoom,
                                                    bands: [FlatRingBand(zoom: 12, distance: 1, tileCount: 9),
                                                            FlatRingBand(zoom: 11, distance: 3, tileCount: 12)],
                                                    flatRenderState: flatRenderState)
    private static var lookAt: Tile {
        let tile = FlatRingRuleCoverage.lookAtTile(targetZoom: targetZoom, flatRenderState: flatRenderState)
        return Tile(x: tile.x, y: tile.y, z: targetZoom)
    }

    /// A tile in its own slot of the near band draws whole.
    func testATileInItsOwnSlotDrawsWhole() {
        let tile = Self.lookAt
        XCTAssertEqual(GroundSlotClip.rects(source: tile, slot: VisibleTile(tile: tile), rings: Self.rings),
                       [SIMD4<Float>(0, 0, 4096, 4096)])
    }

    /// A parent standing in for a child draws the child's quarter of
    /// itself: the east half for an east child, the south half, low in
    /// the tile's y-up units, for a south child. The cut edges reach a
    /// little past the middle, the tile's own edges stay.
    func testAParentStandingInDrawsTheChildsQuarter() throws {
        let child = Self.lookAt
        let parent = try XCTUnwrap(child.findParentTile(atZoom: child.z - 1))
        let rects = GroundSlotClip.rects(source: parent, slot: VisibleTile(tile: child), rings: Self.rings)
        let east = child.x % 2 == 1
        let south = child.y % 2 == 1
        let reach = GroundSlotClip.seamOverlap
        XCTAssertEqual(rects, [SIMD4<Float>(east ? 2048 - reach : 0, south ? 0 : 2048 - reach,
                                            east ? 4096 : 2048 + reach, south ? 2048 + reach : 4096)])
    }

    /// A far band's tile that straddles the near band's square draws
    /// only what lies outside it: the half of the tile beyond the square.
    /// The square's edges lie one tile out from the look-at tile, on an
    /// odd or an even column by the look-at tile's parity, and a zoom 11
    /// tile's edges lie on the even ones, so the straddling tile is the
    /// west neighbour's parent for an even column and the parent two
    /// columns east for an odd one.
    func testAFarTileIsCutAtTheNearBandsSquare() throws {
        let lookAt = Self.lookAt
        let even = lookAt.x % 2 == 0
        let child = Tile(x: even ? lookAt.x - 1 : lookAt.x + 2, y: lookAt.y, z: lookAt.z)
        let parent = try XCTUnwrap(child.findParentTile(atZoom: 11))
        let rects = GroundSlotClip.rects(source: parent, slot: VisibleTile(tile: parent), rings: Self.rings)
        let reach = GroundSlotClip.seamOverlap
        XCTAssertEqual(rects, [even ? SIMD4<Float>(0, 0, 2048 + reach, 4096) : SIMD4<Float>(2048 - reach, 0, 4096, 4096)],
                       "The half beyond the near band's square, reaching past the cut")
        let inside = try XCTUnwrap(lookAt.findParentTile(atZoom: 11))
        XCTAssertTrue(GroundSlotClip.rects(source: inside, slot: VisibleTile(tile: inside), rings: Self.rings).isEmpty,
                      "The look-at tile's parent lies wholly in the near band: nothing of it to draw")
    }

    /// A child standing in for a far band's loading parent is bounded by
    /// the parent's band, not by its own zoom's: the near band is the
    /// child's zoom, and had the child's own tile named the band, the near
    /// band's square would have cut it away. The child draws whole.
    func testAChildStandingInForAFarParentIsBoundedByTheParentsBand() throws {
        let lookAt = Self.lookAt
        let even = lookAt.x % 2 == 0
        let child = Tile(x: even ? lookAt.x - 3 : lookAt.x + 4, y: lookAt.y, z: lookAt.z)
        let parent = try XCTUnwrap(child.findParentTile(atZoom: 11))
        XCTAssertEqual(GroundSlotClip.rects(source: child, slot: VisibleTile(tile: parent), rings: Self.rings),
                       [SIMD4<Float>(0, 0, 4096, 4096)])
        XCTAssertTrue(GroundSlotClip.rects(source: child, slot: VisibleTile(tile: child), rings: Self.rings).isEmpty,
                      "Named by its own tile, the child would fall outside the near band")
    }

    /// A parent standing in for a loading child draws around the
    /// grandchildren already placed in the child's slot: a hole per
    /// grandchild, the rest of the child's quarter in pieces.
    func testAnAncestorDrawsAroundTheDescendantsInItsSlot() throws {
        let child = Self.lookAt
        let parent = try XCTUnwrap(child.findParentTile(atZoom: child.z - 1))
        let grandchild = Tile(x: child.x * 2, y: child.y * 2, z: child.z + 1)
        let rects = GroundSlotClip.rects(source: parent, slot: VisibleTile(tile: child), holes: [grandchild], rings: Self.rings)
        let quarter = GroundSlotClip.rects(source: parent, slot: VisibleTile(tile: child), rings: Self.rings)[0]
        let area = rects.reduce(Float(0)) { $0 + ($1.z - $1.x) * ($1.w - $1.y) }
        // The pieces reach past their cuts by the seam overlap, a few
        // thousand square units over the quarter's four million.
        XCTAssertEqual(area, (quarter.z - quarter.x) * (quarter.w - quarter.y) * 3 / 4, accuracy: 4096 * 4,
                       "Three quarters of the quarter remain")
        // The grandchild, the child's north-west quarter: the parent's
        // units are half the child's, so it is 1024 a side, in the top left
        // (y up) of the child's quarter.
        let hole = SIMD4<Float>(quarter.x, quarter.w - 1024, quarter.x + 1024, quarter.w)
        for rect in rects {
            let centre = SIMD2<Float>((rect.x + rect.z) / 2, (rect.y + rect.w) / 2)
            XCTAssertFalse(centre.x > hole.x && centre.x < hole.z && centre.y > hole.y && centre.y < hole.w,
                           "No piece lies in the grandchild's hole: \(rect)")
        }
    }

    /// Two bands of one zoom, as the rules give near the floor zoom, are
    /// one band to the clip: a tile of the outer one is not cut at the
    /// inner one's square.
    func testBandsOfOneZoomAreOneBandToTheClip() throws {
        let lookAt = Self.lookAt
        let rings = GroundSlotClip.Rings(targetZoom: Self.targetZoom,
                                         bands: [FlatRingBand(zoom: 12, distance: 1, tileCount: 9),
                                                 FlatRingBand(zoom: 11, distance: 2, tileCount: 4),
                                                 FlatRingBand(zoom: 11, distance: 4, tileCount: 12)],
                                         flatRenderState: Self.flatRenderState)
        // A zoom 11 tile three target tiles out: outside the first zoom 11
        // band's square (two rings), inside the second's (four rings).
        let child = Tile(x: lookAt.x + 3, y: lookAt.y, z: lookAt.z)
        let far = try XCTUnwrap(child.findParentTile(atZoom: 11))
        let rects = GroundSlotClip.rects(source: far, slot: VisibleTile(tile: far), rings: rings)
        XCTAssertFalse(rects.isEmpty, "The tile lies in the zoom 11 band, whichever of its two rings")
        let area = rects.reduce(Float(0)) { $0 + ($1.z - $1.x) * ($1.w - $1.y) }
        XCTAssertGreaterThan(area, 0)
    }

    /// Nothing is drawn by a source placed where its band leaves it no
    /// ground: a near tile's slot lying wholly outside the near band.
    func testASlotOutsideItsBandDrawsNothing() {
        let lookAt = Self.lookAt
        let far = Tile(x: lookAt.x + 5, y: lookAt.y, z: lookAt.z)
        XCTAssertTrue(GroundSlotClip.rects(source: far, slot: VisibleTile(tile: far), rings: Self.rings).isEmpty)
    }
}

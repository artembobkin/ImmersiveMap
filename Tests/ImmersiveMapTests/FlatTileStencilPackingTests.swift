// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The flat map's stencil reference packs the ring above the zoom, so one
/// greaterEqual test keeps a tile off the nearer rings and, on its own
/// ring, under the finer tiles.
final class FlatTileStencilPackingTests: XCTestCase {
    /// The default rules at a street zoom: four bands, four rings.
    private let bands = [FlatRingBand(zoom: 14, distance: 1, tileCount: 9),
                         FlatRingBand(zoom: 13, distance: 2, tileCount: 8),
                         FlatRingBand(zoom: 12, distance: 3, tileCount: 8),
                         FlatRingBand(zoom: 10, distance: 9, tileCount: 20)]

    func testTheNearestRingRanksHighestAndTheRingsSplitTheBits() {
        let packing = FlatTileStencilPacking(bands: bands, targetZoom: 14)
        XCTAssertEqual(packing.rings.map(\.rank), [4, 3, 2, 1])
        XCTAssertEqual(packing.rings.map(\.distance), [1, 2, 3, 9])
        XCTAssertEqual(packing.zoomBits, 3, "Four ranks take three bits, the zoom keeps three")
        XCTAssertEqual(packing.maximumZoomCode, 7)
        let single = FlatTileStencilPacking(bands: [bands[0]], targetZoom: 14)
        XCTAssertEqual(single.zoomBits, 5, "One ring takes one bit")
    }

    func testEveryReferenceAndMarkFitsThePriorityBits() {
        let packing = FlatTileStencilPacking(bands: bands, targetZoom: 14)
        for ring in packing.rings {
            XCTAssertEqual(packing.ringMark(ring) & ~TileSourceStencilPriority.priorityMask, 0)
            for sourceZoom in 0 ... 22 {
                let reference = packing.reference(sourceZoom: sourceZoom, slotZoom: ring.zoom)
                XCTAssertEqual(reference & ~TileSourceStencilPriority.priorityMask, 0, "\(sourceZoom) in \(ring)")
                XCTAssertNotEqual(reference & TileSourceStencilPriority.priorityMask, 0, "0 is nobody's")
            }
        }
        XCTAssertEqual(TileSourceStencilPriority.priorityMask & TileSourceStencilPriority.surfaceMaskBit, 0)
        XCTAssertEqual(TileSourceStencilPriority.priorityMask & TileSourceStencilPriority.groundHoleBit, 0)
    }

    /// A tile of a far ring passes its own ring's mark and the farther
    /// rings', and fails a nearer ring's mark whatever its zoom.
    func testAFarRingsTileFailsANearerRingsMark() {
        let packing = FlatTileStencilPacking(bands: bands, targetZoom: 14)
        let near = packing.rings[0]
        let second = packing.rings[1]
        let third = packing.rings[2]
        let secondRingTile = packing.reference(sourceZoom: 13, slotZoom: 13)
        XCTAssertGreaterThanOrEqual(secondRingTile, packing.ringMark(second), "Its own ring")
        XCTAssertGreaterThanOrEqual(secondRingTile, packing.ringMark(third), "A farther ring")
        XCTAssertLessThan(secondRingTile, packing.ringMark(near), "Never the nearer ring")
        let fineStandIn = packing.reference(sourceZoom: 16, slotZoom: 13)
        XCTAssertLessThan(fineStandIn, packing.ringMark(near), "However fine the source")
        let nearRingStandIn = packing.reference(sourceZoom: 12, slotZoom: 14)
        XCTAssertGreaterThanOrEqual(nearRingStandIn, packing.ringMark(near), "A stand-in placed in the near ring draws there")
    }

    /// On one ring the finer source wins: its reference is above the
    /// coarser one's mark, and the coarser one's is below its mark.
    func testOnOneRingTheFinerSourceWins() {
        let packing = FlatTileStencilPacking(bands: bands, targetZoom: 14)
        let own = packing.reference(sourceZoom: 14, slotZoom: 14)
        let parent = packing.reference(sourceZoom: 13, slotZoom: 14)
        let grandparent = packing.reference(sourceZoom: 12, slotZoom: 14)
        XCTAssertGreaterThan(own, parent)
        XCTAssertGreaterThan(parent, grandparent)
        XCTAssertEqual(packing.reference(sourceZoom: 15, slotZoom: 14), own, "Finer than the target shares the top code")
        XCTAssertEqual(packing.reference(sourceZoom: 7, slotZoom: 14), packing.reference(sourceZoom: 0, slotZoom: 14),
                       "Far above the target the levels share the lowest code")
    }

    /// Consecutive bands of one zoom are one ring: their tiles are the
    /// same tiles.
    func testBandsOfOneZoomAreOneRing() {
        let floored = [FlatRingBand(zoom: 3, distance: 1, tileCount: 9),
                       FlatRingBand(zoom: 3, distance: 2, tileCount: 8),
                       FlatRingBand(zoom: 2, distance: 3, tileCount: 8)]
        let packing = FlatTileStencilPacking(bands: floored, targetZoom: 3)
        XCTAssertEqual(packing.rings.map(\.zoom), [3, 2])
        XCTAssertEqual(packing.rings.map(\.distance), [2, 3], "The ring's square is its last band's")
        XCTAssertEqual(packing.rings.map(\.rank), [2, 1])
    }

    /// The sphere keeps its reference, the zoom shifted off the cleared
    /// value, inside the same bits.
    func testTheSpheresReferenceFitsTheSameBits() {
        XCTAssertEqual(TileSourceStencilPriority.reference(sourceZoom: 16) & ~TileSourceStencilPriority.priorityMask, 0)
    }
}

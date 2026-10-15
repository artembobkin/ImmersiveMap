// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The flat map's tile-priority value (`FlatTileStencilPacking`): the
/// zoom of a source, the planner's mark that the placement prepass
/// writes and every ground pass tests equal to.
final class FlatTileStencilPackingTests: XCTestCase {
    func testEveryZoomHasItsOwnValue() {
        var values = Set<UInt32>()
        for zoom in 0 ... 22 {
            XCTAssertTrue(values.insert(FlatTileStencilPacking.reference(sourceZoom: zoom)).inserted,
                          "Two zooms never share a value, or a tile would paint another zoom's ground")
        }
    }

    func testEveryValueFitsThePriorityBitsAndNoneIsTheClearedStencil() {
        for zoom in 0 ... 30 {
            let value = FlatTileStencilPacking.reference(sourceZoom: zoom)
            XCTAssertEqual(value & ~TileSourceStencilPriority.priorityMask, 0, "Inside the six bits")
            XCTAssertNotEqual(value, 0, "0 is ground nobody was given")
        }
        XCTAssertEqual(FlatTileStencilPacking.reference(sourceZoom: 40), FlatTileStencilPacking.zoomMask,
                       "A zoom past the bits shares the last value")
    }

    func testTheSpheresReferenceFitsTheSameBits() {
        for zoom in 0 ... 22 {
            let value = TileSourceStencilPriority.reference(sourceZoom: zoom)
            XCTAssertEqual(value & ~TileSourceStencilPriority.priorityMask, 0)
            XCTAssertNotEqual(value, 0)
        }
    }
}

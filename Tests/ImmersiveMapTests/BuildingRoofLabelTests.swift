// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// A label standing on a roof: the roof over its anchor from the volumes a
/// tile draws (`BuildingRoofLookup`), which the flat projection lifts the
/// label by wherever the tile came from.
final class BuildingRoofLabelTests: XCTestCase {
    /// A candidate over a square given in render space (y up), the space
    /// the resolver's candidates live in.
    private func makeCandidate(buildingId: UInt64,
                               exterior: [SIMD2<Float>],
                               interiors: [[SIMD2<Float>]] = [],
                               topHeight: Float) -> BuildingExtrusionCandidate {
        let signature = BuildingFootprintSignature(
            exterior: exterior.map { UInt64(UInt32(bitPattern: Int32($0.x.rounded()))) << 32
                | UInt64(UInt32(bitPattern: Int32($0.y.rounded()))) },
            interiors: []
        )
        let roofVertices = exterior.map { SIMD2<Int16>(Int16($0.x.rounded()), Int16($0.y.rounded())) }
        return BuildingExtrusionCandidate(styleKey: 1,
                                          buildingId: buildingId,
                                          isPart: false,
                                          footprintSignature: signature,
                                          clippedExterior: exterior,
                                          clippedInteriors: interiors,
                                          roof: ParsedPolygon(vertices: roofVertices, indices: [0, 1, 2]),
                                          baseHeight: 0,
                                          topHeight: topHeight)
    }

    private func square(x: Float, y: Float, size: Float) -> [SIMD2<Float>] {
        [SIMD2(x, y), SIMD2(x + size, y), SIMD2(x + size, y + size), SIMD2(x, y + size)]
    }

    /// The tile-space point (y down) over a render-space point.
    private func tilePoint(_ x: Float, _ renderY: Float) -> SIMD2<Int16> {
        SIMD2(Int16(x), Int16(4096 - renderY))
    }

    func testAPointInsideAFootprintTakesItsRoof() {
        let roofs = BuildingRoofLookup(candidates: [makeCandidate(buildingId: 1,
                                                                  exterior: square(x: 1000, y: 1000, size: 200),
                                                                  topHeight: 90)])

        XCTAssertEqual(roofs.roofHeight(atTilePoint: tilePoint(1100, 1100)), 90)
        XCTAssertEqual(roofs.roofHeight(atTilePoint: tilePoint(1300, 1100)), 0, "open ground has no roof")
    }

    /// A tower on its podium: the label takes the tower's top, the way the
    /// skyline reads.
    func testOverlappingVolumesAnswerTheTallest() {
        let roofs = BuildingRoofLookup(candidates: [
            makeCandidate(buildingId: 1, exterior: square(x: 1000, y: 1000, size: 400), topHeight: 20),
            makeCandidate(buildingId: 2, exterior: square(x: 1100, y: 1100, size: 100), topHeight: 300)
        ])

        XCTAssertEqual(roofs.roofHeight(atTilePoint: tilePoint(1150, 1150)), 300)
        XCTAssertEqual(roofs.roofHeight(atTilePoint: tilePoint(1350, 1350)), 20)
    }

    func testACourtyardIsNotUnderTheRoof() {
        let roofs = BuildingRoofLookup(candidates: [
            makeCandidate(buildingId: 1,
                          exterior: square(x: 1000, y: 1000, size: 300),
                          interiors: [square(x: 1100, y: 1100, size: 100)],
                          topHeight: 40)
        ])

        XCTAssertEqual(roofs.roofHeight(atTilePoint: tilePoint(1150, 1150)), 0)
        XCTAssertEqual(roofs.roofHeight(atTilePoint: tilePoint(1050, 1050)), 40)
    }

    /// A footprint spanning grid cells is found from every cell it covers.
    func testAFootprintAcrossGridCellsIsFoundFromEachCell() {
        let roofs = BuildingRoofLookup(candidates: [makeCandidate(buildingId: 1,
                                                                  exterior: square(x: 200, y: 200, size: 400),
                                                                  topHeight: 50)])

        XCTAssertEqual(roofs.roofHeight(atTilePoint: tilePoint(210, 210)), 50)
        XCTAssertEqual(roofs.roofHeight(atTilePoint: tilePoint(590, 590)), 50)
    }

    /// The roof and the lift flag sit after the tile slot, in the layout
    /// the prepared tile format writes.
    func testTheRoofKeepsThePointInputLayout() {
        XCTAssertEqual(MemoryLayout<TilePointInput>.stride, 48)
        XCTAssertEqual(MemoryLayout<TilePointInput>.offset(of: \.roofHeight), 36)
        XCTAssertEqual(MemoryLayout<TilePointInput>.offset(of: \.liftsToRoof), 40)
        XCTAssertEqual(MemoryLayout<TilePointInput>.offset(of: \.roofIsReplaced), 44)
    }

    /// A building a landmark model stands in for keeps its roof for the
    /// labels in it, marked as replaced so the frame takes the model's top
    /// there, and only there: the buildings around it keep their own.
    func testAReplacedBuildingsRoofIsMarkedAsReplaced() {
        let roofs = BuildingRoofLookup(
            candidates: [makeCandidate(buildingId: 1, exterior: square(x: 1000, y: 1000, size: 200), topHeight: 12)],
            replacedCandidates: [makeCandidate(buildingId: 2, exterior: square(x: 2000, y: 2000, size: 200), topHeight: 80)])

        XCTAssertEqual(roofs.roof(atTilePoint: tilePoint(1100, 1100)), BuildingRoofLookup.Roof(height: 12, isReplaced: false))
        XCTAssertEqual(roofs.roof(atTilePoint: tilePoint(2100, 2100)), BuildingRoofLookup.Roof(height: 80, isReplaced: true))
        XCTAssertEqual(roofs.roof(atTilePoint: tilePoint(3000, 3000)), .none)
    }
}

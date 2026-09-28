// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// A label standing on a roof: the roof over its anchor from the volumes a
/// tile draws (`BuildingRoofLookup`), and the slots where the frame draws
/// buildings, the only places the label is lifted (`BuildingRoofCoverage`).
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

    // MARK: - Coverage

    private func coverage(slots: [VisibleTile]) throws -> BuildingRoofCoverage {
        let metalTile = MetalTile(tile: Tile(x: 0, y: 0, z: 14),
                                  tileBuffers: try TileBuffersFixtures.makeEmptyTileBuffers())
        return BuildingRoofCoverage(placeTilesContext: PlaceTilesContext(
            tilePlacements: slots.map { PlaceTile(metalTile: metalTile, placeIn: $0) }))
    }

    func testAPointIsLiftedOnlyInsideASlotThatDrawsBuildings() throws {
        let coverage = try coverage(slots: [VisibleTile(x: 100, y: 200, z: 14)])

        // A z15 label tile inside the z14 slot, and one beside it.
        XCTAssertTrue(coverage.drawsBuildings(tile: SIMD3(201, 401, 15), uv: SIMD2(0.5, 0.5)))
        XCTAssertFalse(coverage.drawsBuildings(tile: SIMD3(202, 401, 15), uv: SIMD2(0.5, 0.5)))
    }

    /// A clipped slot finer than the label's tile covers only its own part
    /// of that tile.
    func testAFinerSlotCoversOnlyItsPartOfACoarserLabelTile() throws {
        let coverage = try coverage(slots: [VisibleTile(x: 200, y: 400, z: 15)])

        XCTAssertTrue(coverage.drawsBuildings(tile: SIMD3(100, 200, 14), uv: SIMD2(0.25, 0.25)))
        XCTAssertFalse(coverage.drawsBuildings(tile: SIMD3(100, 200, 14), uv: SIMD2(0.75, 0.25)))
    }

    func testNoCoverageLiftsNothing() {
        XCTAssertFalse(BuildingRoofCoverage.none.drawsBuildings(tile: SIMD3(100, 200, 14), uv: SIMD2(0.5, 0.5)))
    }

    /// The roof rides in what was padding: the stride stays the one the
    /// GPU mirror (`TilePointInputGpu`) reads.
    func testTheRoofKeepsThePointInputLayout() {
        XCTAssertEqual(MemoryLayout<TilePointInput>.stride, 48)
        XCTAssertEqual(MemoryLayout<TilePointInput>.offset(of: \.roofHeight), 36)
    }
}

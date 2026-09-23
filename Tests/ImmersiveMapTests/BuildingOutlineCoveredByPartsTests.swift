// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Simple 3D Buildings without a building id: an outline that parts
/// standing on the ground already trace is left out, so the outline and the
/// part never put two lids in one plane. The Protomaps basemap ships the
/// Four Seasons block on Okhotny Ryad this way: a 24 m outline with a
/// courtyard, and a 20 m part with a vertex less and a larger courtyard.
final class BuildingOutlineCoveredByPartsTests: XCTestCase {
    func testAnOutlineTracedByAGroundPartIsLeftOut() {
        let outline = candidate(id: 1, isPart: false,
                                exterior: rectangle(0, 0, 1000, 800),
                                courtyard: rectangle(300, 250, 400, 300),
                                base: 0, top: 96)
        // The part traces the outline a little inside, with a vertex more on
        // one side and a courtyard drawn larger than the outline's.
        let part = candidate(id: 2, isPart: true,
                             exterior: [SIMD2(4, 3), SIMD2(500, 2), SIMD2(996, 4),
                                        SIMD2(997, 797), SIMD2(3, 796)],
                             courtyard: rectangle(280, 230, 440, 340),
                             base: 0, top: 80)

        let kept = BuildingExtrusionResolver.resolveExterior([outline, part])

        XCTAssertEqual(kept.map(\.buildingId), [2], "Only the part rises: the outline it traces goes")
    }

    func testPartsFloatingAboveTheGroundNeverReplaceTheOutline() {
        let outline = candidate(id: 1, isPart: false, exterior: rectangle(0, 0, 1000, 800),
                                courtyard: nil, base: 0, top: 96)
        let roofSlab = candidate(id: 2, isPart: true, exterior: rectangle(0, 0, 1000, 800),
                                 courtyard: nil, base: 80, top: 96)

        let kept = BuildingExtrusionResolver.resolveExterior([outline, roofSlab])

        // The outline stays: a slab does not stand in for the walls below
        // it. The slab itself lies wholly inside the outline, lid in the
        // plane of the outline's, so it is the one that goes.
        XCTAssertEqual(kept.map(\.buildingId), [1])
    }

    func testAnOutlineOnlyPartlyCoveredByPartsStays() {
        let outline = candidate(id: 1, isPart: false, exterior: rectangle(0, 0, 1000, 800),
                                courtyard: nil, base: 0, top: 96)
        let wing = candidate(id: 2, isPart: true, exterior: rectangle(0, 0, 400, 800),
                             courtyard: nil, base: 0, top: 120)

        let kept = BuildingExtrusionResolver.resolveExterior([outline, wing])

        XCTAssertEqual(Set(kept.map(\.buildingId)), [1, 2],
                       "A part over two fifths of the footprint leaves the rest to the outline")
    }

    func testTheCourtyardIsNotCountedAsFootprint() {
        // The part covers the building's wings but not its courtyard. The
        // courtyard is no footprint, so the wings alone are full coverage.
        let outline = candidate(id: 1, isPart: false,
                                exterior: rectangle(0, 0, 1000, 800),
                                courtyard: rectangle(200, 200, 600, 400),
                                base: 0, top: 96)
        let part = candidate(id: 2, isPart: true,
                             exterior: rectangle(0, 0, 1000, 800),
                             courtyard: rectangle(200, 200, 600, 400),
                             base: 0, top: 80)

        let kept = BuildingExtrusionResolver.resolveExterior([outline, part])

        XCTAssertEqual(kept.map(\.buildingId), [2])
    }

    func testADuplicateOutlineIsDrawnOnce() {
        let first = candidate(id: 1, isPart: false, exterior: rectangle(0, 0, 500, 400),
                              courtyard: nil, base: 0, top: 20)
        let second = candidate(id: 2, isPart: false, exterior: rectangle(0, 0, 500, 400),
                               courtyard: nil, base: 0, top: 20)

        let kept = BuildingExtrusionResolver.resolveExterior([first, second])

        XCTAssertEqual(kept.map(\.buildingId), [1], "Of two identical volumes the first stays")
    }

    func testAPartStandingAboveItsOutlineStays() {
        let outline = candidate(id: 1, isPart: false, exterior: rectangle(0, 0, 1000, 800),
                                courtyard: nil, base: 0, top: 96)
        let tower = candidate(id: 2, isPart: true, exterior: rectangle(100, 100, 200, 200),
                              courtyard: nil, base: 0, top: 200)

        let kept = BuildingExtrusionResolver.resolveExterior([outline, tower])

        XCTAssertEqual(Set(kept.map(\.buildingId)), [1, 2], "A tower rising out of the roof is seen")
    }

    // MARK: - Fixtures

    private func rectangle(_ x: Float, _ y: Float, _ width: Float, _ height: Float) -> [SIMD2<Float>] {
        [SIMD2(x, y), SIMD2(x + width, y), SIMD2(x + width, y + height), SIMD2(x, y + height)]
    }

    private func candidate(id: UInt64,
                           isPart: Bool,
                           exterior: [SIMD2<Float>],
                           courtyard: [SIMD2<Float>]?,
                           base: Float,
                           top: Float) -> BuildingExtrusionCandidate {
        let pack: ([SIMD2<Float>]) -> [UInt64] = { ring in
            ring.map { UInt64(UInt32(bitPattern: Int32($0.x.rounded()))) << 32
                | UInt64(UInt32(bitPattern: Int32($0.y.rounded()))) }
        }
        let interiors = courtyard.map { [Array($0.reversed())] } ?? []
        return BuildingExtrusionCandidate(
            styleKey: 1,
            buildingId: id,
            isPart: isPart,
            footprintSignature: BuildingFootprintSignature(exterior: pack(exterior),
                                                           interiors: interiors.map(pack)),
            clippedExterior: exterior,
            clippedInteriors: interiors,
            roof: ParsedPolygon(vertices: exterior.map { SIMD2<Int16>(Int16($0.x), Int16($0.y)) },
                                indices: [0, 1, 2]),
            baseHeight: base,
            topHeight: top
        )
    }
}

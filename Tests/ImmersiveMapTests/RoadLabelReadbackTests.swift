// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class RoadLabelReadbackTests: XCTestCase {
    func testMakeRoadInstanceCandidatesBuildsCandidatesFromGpuOutputs() {
        let placements = [
            Self.makePlacement(position: SIMD2<Float>(10, 20), angle: 0.1),
            Self.makePlacement(position: SIMD2<Float>(30, 40), angle: 0.2),
            Self.makePlacement(position: SIMD2<Float>(99, 99), angle: 0.3)
        ]
        let collisionAabbs = [
            RoadGlyphCollisionOutput(halfSizeAABB: SIMD2<Float>(4, 6)),
            RoadGlyphCollisionOutput(halfSizeAABB: SIMD2<Float>(5, 7)),
            RoadGlyphCollisionOutput(halfSizeAABB: SIMD2<Float>(1, 1))
        ]

        let candidates = Self.makeCandidates(glyphRange: 0..<2,
                                             placements: placements,
                                             collisionAabbs: collisionAabbs)

        XCTAssertEqual(candidates?.count, 2)
        XCTAssertEqual(candidates?[0].position, SIMD2<Float>(10, 20))
        XCTAssertEqual(candidates?[0].halfSize, SIMD2<Float>(4, 6))
        XCTAssertEqual(candidates?[1].position, SIMD2<Float>(30, 40))
        XCTAssertEqual(candidates?[1].halfSize, SIMD2<Float>(5, 7))
        XCTAssertEqual(candidates?[0].priority, 1_000_000_000)
        XCTAssertEqual(candidates?[0].secondaryPriority, 7)
        XCTAssertEqual(candidates?[0].sortPriority, 3)
        XCTAssertEqual(candidates?[0].stableOrderKey, 42)
        XCTAssertEqual(candidates?[0].groupId, 42)
    }

    func testMakeRoadInstanceCandidatesRejectsInstanceWithInvisibleGlyph() {
        // "All or nothing", like the previous CPU path: an invisible glyph
        // (path behind the camera or shorter than the label) cancels the instance decision.
        let placements = [
            Self.makePlacement(position: SIMD2<Float>(10, 20), angle: 0),
            Self.makePlacement(position: .zero, angle: 0, visible: 0)
        ]
        let collisionAabbs = [
            RoadGlyphCollisionOutput(halfSizeAABB: SIMD2<Float>(4, 6)),
            RoadGlyphCollisionOutput(halfSizeAABB: .zero)
        ]

        XCTAssertNil(Self.makeCandidates(glyphRange: 0..<2,
                                         placements: placements,
                                         collisionAabbs: collisionAabbs))
    }

    func testMakeRoadInstanceCandidatesRejectsExtrapolatedGlyph() {
        // A glyph extrapolated past the end of the path is drawn by the shader,
        // but the previous CPU path did not show such instances - no decision is made.
        let placements = [
            Self.makePlacement(position: SIMD2<Float>(10, 20), angle: 0),
            Self.makePlacement(position: SIMD2<Float>(30, 40), angle: 0, extrapolated: 1)
        ]
        let collisionAabbs = [
            RoadGlyphCollisionOutput(halfSizeAABB: SIMD2<Float>(4, 6)),
            RoadGlyphCollisionOutput(halfSizeAABB: SIMD2<Float>(5, 7))
        ]

        XCTAssertNil(Self.makeCandidates(glyphRange: 0..<2,
                                         placements: placements,
                                         collisionAabbs: collisionAabbs))
    }

    func testMakeRoadInstanceCandidatesRejectsSharpGlyphTurn() {
        // The maxGlyphTurnRadians gate over the angles of actually drawn glyphs:
        // a sharp bend between adjacent glyphs hides the instance.
        let placements = [
            Self.makePlacement(position: SIMD2<Float>(10, 20), angle: 0),
            Self.makePlacement(position: SIMD2<Float>(30, 40), angle: 1.2)
        ]
        let collisionAabbs = [
            RoadGlyphCollisionOutput(halfSizeAABB: SIMD2<Float>(4, 6)),
            RoadGlyphCollisionOutput(halfSizeAABB: SIMD2<Float>(5, 7))
        ]

        XCTAssertNil(Self.makeCandidates(glyphRange: 0..<2,
                                         placements: placements,
                                         collisionAabbs: collisionAabbs,
                                         maxGlyphTurnRadians: 1.0))
        XCTAssertEqual(Self.makeCandidates(glyphRange: 0..<2,
                                           placements: placements,
                                           collisionAabbs: collisionAabbs,
                                           maxGlyphTurnRadians: 1.5)?.count, 2)
    }

    func testMakeRoadInstanceCandidatesNormalizesAngleWrapAroundPi() {
        // Angles of ±π are the same turn (reverse adds π): after normalization
        // the delta is small, the instance must not be rejected.
        let placements = [
            Self.makePlacement(position: SIMD2<Float>(10, 20), angle: .pi - 0.05),
            Self.makePlacement(position: SIMD2<Float>(30, 40), angle: -.pi + 0.05)
        ]
        let collisionAabbs = [
            RoadGlyphCollisionOutput(halfSizeAABB: SIMD2<Float>(4, 6)),
            RoadGlyphCollisionOutput(halfSizeAABB: SIMD2<Float>(5, 7))
        ]

        XCTAssertEqual(Self.makeCandidates(glyphRange: 0..<2,
                                           placements: placements,
                                           collisionAabbs: collisionAabbs,
                                           maxGlyphTurnRadians: 0.5)?.count, 2)
    }

    func testMakeRoadInstanceCandidatesRejectsOutOfBoundsRange() {
        let placements = [
            Self.makePlacement(position: SIMD2<Float>(10, 20), angle: 0)
        ]
        let collisionAabbs = [
            RoadGlyphCollisionOutput(halfSizeAABB: SIMD2<Float>(4, 6))
        ]

        XCTAssertNil(Self.makeCandidates(glyphRange: 0..<2,
                                         placements: placements,
                                         collisionAabbs: collisionAabbs))
        XCTAssertNil(Self.makeCandidates(glyphRange: 0..<0,
                                         placements: placements,
                                         collisionAabbs: collisionAabbs))
    }

    private static func makePlacement(position: SIMD2<Float>,
                                      angle: Float,
                                      visible: UInt32 = 1,
                                      extrapolated: UInt32 = 0) -> RoadGlyphPlacementOutput {
        RoadGlyphPlacementOutput(position: position,
                                 angle: angle,
                                 visible: visible,
                                 extrapolated: extrapolated)
    }

    private static func makeCandidates(glyphRange: Range<Int>,
                                       placements: [RoadGlyphPlacementOutput],
                                       collisionAabbs: [RoadGlyphCollisionOutput],
                                       maxGlyphTurnRadians: Float = .pi / 6) -> [ScreenCollisionCandidate]? {
        placements.withUnsafeBufferPointer { placementsBuffer in
            collisionAabbs.withUnsafeBufferPointer { collisionAabbsBuffer in
                BaseLabelPrepareSubsystem.makeRoadInstanceCandidates(instanceKey: 42,
                                                                     secondaryPriority: 7,
                                                                     anchorOrdinal: 3,
                                                                     glyphRange: glyphRange,
                                                                     placements: placementsBuffer,
                                                                     collisionAabbs: collisionAabbsBuffer,
                                                                     roadPriorityBase: 1_000_000_000,
                                                                     maxGlyphTurnRadians: maxGlyphTurnRadians)
            }
        }
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The CPU placement of road glyphs along their projected roads. The
/// placer consumes already-projected screen points, so the tests feed
/// hand-made projections and read the glyph placements. The regression
/// under test: the label must center on the anchor's own projected point
/// (`pointIndex`), not on the anchor's world `t` lerped along the
/// projected segment. That lerp is not a projection under a tilted
/// perspective camera, and labels on long straight segments slid along the
/// road while tilting.
final class RoadLabelPlacerTests: XCTestCase {
    // MARK: - RoadLabelCache.makeAnchorPointInput

    func testAnchorPointInputInterpolatesOnItsSegment() {
        let path = [
            TilePointInput(uv: SIMD2<Float>(0.0, 0.0), tile: SIMD3<Int32>(1, 2, 3)),
            TilePointInput(uv: SIMD2<Float>(0.5, 0.1), tile: SIMD3<Int32>(1, 2, 3)),
            TilePointInput(uv: SIMD2<Float>(0.9, 0.7), tile: SIMD3<Int32>(1, 2, 3))
        ]
        let anchor = RoadLabelAnchor(pathIndex: 0, segmentIndex: 1, t: 0.25, anchorOrdinal: 0)

        let point = RoadLabelCache.makeAnchorPointInput(anchor: anchor, path: path)

        XCTAssertEqual(point.uv.x, 0.6, accuracy: 1e-6)
        XCTAssertEqual(point.uv.y, 0.25, accuracy: 1e-6)
        XCTAssertEqual(point.tile, SIMD3<Int32>(1, 2, 3))
        XCTAssertEqual(point.tileSlotIndex, 0)
    }

    func testAnchorPointInputClampsSegmentIndexAndT() {
        let path = [
            TilePointInput(uv: SIMD2<Float>(0.2, 0.2), tile: SIMD3<Int32>(0, 0, 0)),
            TilePointInput(uv: SIMD2<Float>(0.4, 0.2), tile: SIMD3<Int32>(0, 0, 0))
        ]
        let anchor = RoadLabelAnchor(pathIndex: 0, segmentIndex: 7, t: 1.5, anchorOrdinal: 0)

        let point = RoadLabelCache.makeAnchorPointInput(anchor: anchor, path: path)

        XCTAssertEqual(point.uv.x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(point.uv.y, 0.2, accuracy: 1e-6)
    }

    // MARK: - Placement

    func testGlyphCentersOnProjectedAnchorPoint() {
        // Straight horizontal path, 1000 px on screen. The anchor's own
        // projection sits at x=400: under a tilted camera a world-space
        // mid-segment anchor lands off the screen-length midpoint (x=600 for
        // the old t=0.5 lerp), and the label must follow the projection.
        let output = Self.place(
            pathPoints: [SIMD2<Float>(100, 300), SIMD2<Float>(1100, 300), SIMD2<Float>(400, 300)],
            pathPointCount: 2,
            anchor: RoadLabelPlacer.Anchor(pathIndex: 0, segmentIndex: 0, pointIndex: 2),
            glyphCenters: [50, 10])

        XCTAssertEqual(output.placements[0].visible, 1)
        XCTAssertFalse(output.extrapolated[0])
        XCTAssertEqual(output.placements[0].position.x, 400, accuracy: 0.01)
        XCTAssertEqual(output.placements[0].position.y, 300, accuracy: 0.01)
        XCTAssertEqual(output.placements[0].angle, 0, accuracy: 1e-5)
        // The second glyph keeps its pixel offset from the anchored center.
        XCTAssertEqual(output.placements[1].visible, 1)
        XCTAssertEqual(output.placements[1].position.x, 360, accuracy: 0.01)
        // An upright glyph's box is its own half size.
        XCTAssertEqual(output.boxHalfSizes[0].x, 50, accuracy: 1e-4)
        XCTAssertEqual(output.boxHalfSizes[0].y, 10, accuracy: 1e-4)
    }

    /// A stitched road that hooks back at a junction: the path runs right
    /// along the label's segment and then turns hard back left, so its
    /// chord points left. The text reads along its own span, rightward,
    /// not along the chord.
    func testTheReadingDirectionFollowsTheLabelsSpanNotThePathsChord() {
        let output = Self.place(
            pathPoints: [SIMD2<Float>(100, 300), SIMD2<Float>(700, 300), SIMD2<Float>(0, 900), SIMD2<Float>(400, 300)],
            pathPointCount: 3,
            anchor: RoadLabelPlacer.Anchor(pathIndex: 0, segmentIndex: 0, pointIndex: 3),
            glyphCenters: [50, 10])
        XCTAssertEqual(output.placements[0].visible, 1)
        XCTAssertEqual(cos(output.placements[0].angle), 1, accuracy: 1e-5, "upright along a rightward span")
        XCTAssertEqual(output.placements[1].position.x, 360, accuracy: 0.01, "the left glyph sits to the left")
    }

    /// The mirror case: the label's segment runs left while the chord of the
    /// hooked path points right. The text is turned to read, so the left
    /// glyph of the label still lands on the left of the screen.
    func testALeftwardSpanTurnsTheTextWhateverTheChordSays() {
        let output = Self.place(
            pathPoints: [SIMD2<Float>(700, 300), SIMD2<Float>(100, 300), SIMD2<Float>(800, 900), SIMD2<Float>(400, 300)],
            pathPointCount: 3,
            anchor: RoadLabelPlacer.Anchor(pathIndex: 0, segmentIndex: 0, pointIndex: 3),
            glyphCenters: [50, 10])
        XCTAssertEqual(output.placements[0].visible, 1)
        XCTAssertEqual(cos(output.placements[0].angle), 1, accuracy: 1e-5, "turned by a half turn to read upright")
        XCTAssertEqual(output.placements[1].position.x, 360, accuracy: 0.01, "the left glyph still sits to the left")
    }

    func testInvisibleAnchorPointHidesTheLabel() {
        let output = Self.place(
            pathPoints: [SIMD2<Float>(100, 300), SIMD2<Float>(1100, 300), .zero],
            pathPointCount: 2,
            visible: [true, true, false],
            anchor: RoadLabelPlacer.Anchor(pathIndex: 0, segmentIndex: 0, pointIndex: 2),
            glyphCenters: [50])

        XCTAssertEqual(output.placements[0].visible, 0)
    }

    /// A label wider than the road overhangs an end: the glyph past the
    /// end is drawn on the road's line, but marked so the solve never
    /// offers the instance.
    func testAGlyphPastThePathEndIsExtrapolated() {
        let output = Self.place(
            pathPoints: [SIMD2<Float>(100, 300), SIMD2<Float>(160, 300), SIMD2<Float>(130, 300)],
            pathPointCount: 2,
            anchor: RoadLabelPlacer.Anchor(pathIndex: 0, segmentIndex: 0, pointIndex: 2),
            glyphCenters: [10, 90],
            labelWidth: 100,
            minLength: 0)
        XCTAssertEqual(output.placements[0].position.x, 90, accuracy: 0.01)
        XCTAssertTrue(output.extrapolated[0])
        XCTAssertEqual(output.placements[1].position.x, 170, accuracy: 0.01)
        XCTAssertTrue(output.extrapolated[1])
    }

    /// The screen path is in device pixels and the glyph metrics in points:
    /// the offsets scale with the display.
    func testGlyphOffsetsScaleWithPixelsPerPoint() {
        let output = Self.place(
            pathPoints: [SIMD2<Float>(100, 300), SIMD2<Float>(1100, 300), SIMD2<Float>(400, 300)],
            pathPointCount: 2,
            anchor: RoadLabelPlacer.Anchor(pathIndex: 0, segmentIndex: 0, pointIndex: 2),
            glyphCenters: [50, 10],
            pixelsPerPoint: 2)
        XCTAssertEqual(output.placements[1].position.x, 320, accuracy: 0.01)
        XCTAssertEqual(output.boxHalfSizes[0].x, 100, accuracy: 1e-4)
    }

    // MARK: - Instance boxes

    func testInstanceBoxesComeFromThePlacement() {
        var output = RoadLabelPlacer.Output()
        output.placements = [Self.placement(SIMD2<Float>(10, 20), angle: 0.1),
                             Self.placement(SIMD2<Float>(30, 40), angle: 0.2),
                             Self.placement(SIMD2<Float>(99, 99), angle: 0.3)]
        output.extrapolated = [false, false, false]
        output.boxHalfSizes = [SIMD2<Float>(4, 6), SIMD2<Float>(5, 7), SIMD2<Float>(1, 1)]
        var centers: [SIMD2<Float>] = []
        var halfSizes: [SIMD2<Float>] = []

        XCTAssertTrue(RoadLabelPlacer.appendInstanceBoxes(glyphRange: 0..<2, output: output, maxGlyphTurnRadians: 1,
                                                          centers: &centers, halfSizes: &halfSizes))
        XCTAssertEqual(centers, [SIMD2<Float>(10, 20), SIMD2<Float>(30, 40)])
        XCTAssertEqual(halfSizes, [SIMD2<Float>(4, 6), SIMD2<Float>(5, 7)])
    }

    /// All or nothing: a hidden glyph, one past a path end, or a sharp turn
    /// between neighbours cancels the instance and leaves nothing appended.
    func testAnInstanceIsRejectedWhole() {
        var centers: [SIMD2<Float>] = [SIMD2<Float>(1, 1)]
        var halfSizes: [SIMD2<Float>] = [SIMD2<Float>(1, 1)]

        var hidden = RoadLabelPlacer.Output()
        hidden.placements = [Self.placement(SIMD2<Float>(10, 20), angle: 0), .hidden]
        hidden.extrapolated = [false, false]
        hidden.boxHalfSizes = [SIMD2<Float>(4, 6), .zero]
        XCTAssertFalse(RoadLabelPlacer.appendInstanceBoxes(glyphRange: 0..<2, output: hidden, maxGlyphTurnRadians: 1,
                                                           centers: &centers, halfSizes: &halfSizes))
        XCTAssertEqual(centers.count, 1, "nothing of the rejected instance stays")

        var overhanging = hidden
        overhanging.placements[1] = Self.placement(SIMD2<Float>(30, 40), angle: 0)
        overhanging.extrapolated[1] = true
        XCTAssertFalse(RoadLabelPlacer.appendInstanceBoxes(glyphRange: 0..<2, output: overhanging, maxGlyphTurnRadians: 1,
                                                           centers: &centers, halfSizes: &halfSizes))

        var turning = overhanging
        turning.extrapolated[1] = false
        turning.placements[1].angle = 1.2
        XCTAssertFalse(RoadLabelPlacer.appendInstanceBoxes(glyphRange: 0..<2, output: turning, maxGlyphTurnRadians: 1.0,
                                                           centers: &centers, halfSizes: &halfSizes))
        XCTAssertTrue(RoadLabelPlacer.appendInstanceBoxes(glyphRange: 0..<2, output: turning, maxGlyphTurnRadians: 1.5,
                                                          centers: &centers, halfSizes: &halfSizes))
        XCTAssertEqual(centers.count, 3)
    }

    /// Angles of plus and minus pi are the same turn (reverse adds pi):
    /// after normalization the delta is small and the instance stays.
    func testTheTurnTestNormalizesAroundPi() {
        var output = RoadLabelPlacer.Output()
        output.placements = [Self.placement(SIMD2<Float>(10, 20), angle: .pi - 0.05),
                             Self.placement(SIMD2<Float>(30, 40), angle: -.pi + 0.05)]
        output.extrapolated = [false, false]
        output.boxHalfSizes = [SIMD2<Float>(4, 6), SIMD2<Float>(5, 7)]
        var centers: [SIMD2<Float>] = []
        var halfSizes: [SIMD2<Float>] = []
        XCTAssertTrue(RoadLabelPlacer.appendInstanceBoxes(glyphRange: 0..<2, output: output, maxGlyphTurnRadians: 0.5,
                                                          centers: &centers, halfSizes: &halfSizes))
    }

    func testAnOutOfBoundsRangeGetsNoDecision() {
        var output = RoadLabelPlacer.Output()
        output.placements = [Self.placement(SIMD2<Float>(10, 20), angle: 0)]
        output.extrapolated = [false]
        output.boxHalfSizes = [SIMD2<Float>(4, 6)]
        var centers: [SIMD2<Float>] = []
        var halfSizes: [SIMD2<Float>] = []
        XCTAssertFalse(RoadLabelPlacer.appendInstanceBoxes(glyphRange: 0..<2, output: output, maxGlyphTurnRadians: 1,
                                                           centers: &centers, halfSizes: &halfSizes))
        XCTAssertFalse(RoadLabelPlacer.appendInstanceBoxes(glyphRange: 0..<0, output: output, maxGlyphTurnRadians: 1,
                                                           centers: &centers, halfSizes: &halfSizes))
    }

    // MARK: - Helpers

    private static func placement(_ position: SIMD2<Float>, angle: Float) -> RoadGlyphPlacementOutput {
        RoadGlyphPlacementOutput(position: position, angle: angle, visible: 1)
    }

    /// One path of `pathPointCount` points followed by the anchor's own
    /// point, one instance with a glyph per centre.
    private static func place(pathPoints: [SIMD2<Float>],
                              pathPointCount: Int,
                              visible: [Bool]? = nil,
                              anchor: RoadLabelPlacer.Anchor,
                              glyphCenters: [Float],
                              labelWidth: Float = 100,
                              minLength: Float = 100,
                              pixelsPerPoint: Float = 1) -> RoadLabelPlacer.Output {
        let glyphs = glyphCenters.map { center in
            RoadGlyphInput(pathIndex: 0, instanceIndex: 0, labelInstanceIndex: 0,
                           glyphCenter: center, labelCenterY: 0, labelWidth: labelWidth,
                           spacing: 0, minLength: minLength)
        }
        let geometry = RoadLabelPlacer.Geometry(
            pathPoints: Array(repeating: TilePointInput(uv: .zero, tile: .zero), count: pathPoints.count),
            pathRanges: [0..<pathPointCount],
            pathInstanceRanges: [0..<1],
            anchors: [anchor],
            instanceGlyphRanges: [0..<glyphs.count],
            glyphs: glyphs,
            glyphHalfSizes: Array(repeating: SIMD2<Float>(50, 10), count: glyphs.count))
        var cumulative: [Float] = []
        var output = RoadLabelPlacer.Output()
        RoadLabelPlacer.place(geometry: geometry,
                              screenPoints: pathPoints,
                              visible: visible ?? Array(repeating: true, count: pathPoints.count),
                              pixelsPerPoint: pixelsPerPoint,
                              cumulative: &cumulative,
                              output: &output)
        return output
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

/// The road sheet: every road group drawn as one sheet, each pixel blended
/// once. The colour stage tests a body's depth for equality with what the
/// depth stage wrote, from a differently compiled shader, so the depths
/// have to be exact in a float, and the groups' bands have to sit in the
/// order the groups paint in.
final class RoadSheetContractTests: XCTestCase {
    func testEveryDepthIsAWholeNumberOfStepsUnderOne() {
        let step = RoadSheetDepth.depthStep
        XCTAssertEqual(step, Float(sign: .plus, exponent: -23, significand: 1), "the step is a power of two")
        for group in [0, 1, 20, 40] {
            let base = RoadSheetDepth.baseDepth(group: group)
            for rank in [1, 2, RoadSheetDepth.ranksPerGroup] {
                let depth = base - Float(rank) * step
                let steps = Double(1 - depth) / Double(step)
                XCTAssertEqual(steps, steps.rounded(), "group \(group) rank \(rank) is off the step grid")
                XCTAssertLessThan(depth, base)
            }
        }
    }

    func testALaterGroupIsNearerThanEveryRankOfTheGroupBeforeIt() {
        for group in 0 ..< 24 {
            let nearestOfThis = RoadSheetDepth.baseDepth(group: group)
                - Float(RoadSheetDepth.ranksPerGroup) * RoadSheetDepth.depthStep
            XCTAssertLessThan(RoadSheetDepth.baseDepth(group: group + 1), nearestOfThis)
        }
    }

    func testTheSheetStartsNearerThanTheGroundBands() {
        XCTAssertLessThanOrEqual(RoadSheetDepth.baseDepth(group: 0),
                                 1 - GlobeSurfaceDepthRank.flatRoadsDepthOffset)
    }

    func testAFringeClaimsNothingInTheDepthStageAndTheFarEndInTheColourStage() {
        let depthStage = RoadSheetDepth.uniform(group: 3, stage: .depth)
        let colorStage = RoadSheetDepth.uniform(group: 3, stage: .color)
        XCTAssertEqual(depthStage.fringeDepth, 1)
        XCTAssertEqual(colorStage.fringeDepth, colorStage.baseDepth)
        XCTAssertEqual(depthStage.baseDepth, colorStage.baseDepth)
        // A fragment that is a body in the depth stage is one in the colour
        // stage whatever the two stages round apart.
        XCTAssertGreaterThan(depthStage.bodyCoverage, colorStage.bodyCoverage)
        // The colour stage tests one rank nearer, and the nearest rank it
        // can ask for is still inside the sheet's band.
        XCTAssertEqual(depthStage.rankBias, 0)
        XCTAssertEqual(colorStage.rankBias, 1)
        XCTAssertLessThanOrEqual(Int(colorStage.maximumRank) + 1 + Int(colorStage.rankBias),
                                 RoadSheetDepth.ranksPerGroup)
    }

    func testTheSheetBitSitsOutsideThePriorityAndTheSurfaceMask() {
        XCTAssertEqual(TileSourceStencilPriority.roadSheetBit & TileSourceStencilPriority.priorityMask, 0)
        XCTAssertEqual(TileSourceStencilPriority.roadSheetBit & TileSourceStencilPriority.surfaceMaskBit, 0)
        // Every priority fits the mask, and sits under the sheet's bit, which
        // is what makes greaterEqual fail wherever the bit is raised.
        let finest = TileSourceStencilPriority.reference(sourceZoom: 22)
        XCTAssertEqual(finest & TileSourceStencilPriority.priorityMask, finest)
        XCTAssertLessThan(finest, TileSourceStencilPriority.roadSheetBit)
    }

    func testSwiftAndMetalUniformsAgree() throws {
        XCTAssertEqual(MemoryLayout<RoadSheetUniform>.stride, 24)
        let source = try shaderSource("Tile/Shaders/Tile.metal")
        let structRange = try XCTUnwrap(source.range(of: "struct RoadSheetUniform {"))
        let body = source[structRange.upperBound...]
        var cursor = body.startIndex
        for field in ["float baseDepth;", "float depthStep;", "float fringeDepth;",
                      "float maximumRank;", "float bodyCoverage;", "float rankBias;"] {
            let range = try XCTUnwrap(body.range(of: field, range: cursor ..< body.endIndex), field)
            cursor = range.upperBound
        }
    }

    private func shaderSource(_ relativePath: String) throws -> String {
        let packageRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRootURL.appendingPathComponent("Sources/ImmersiveMap").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// A ribbon clipped at the tile's edge (`ParseLine.clipToTile`) keeps the
/// winding of every triangle counter-clockwise in render space, the thin
/// slivers of a gently bending join's fan included. The clip fans every
/// piece anew, and the ring's area it read the winding from was a float
/// over absolute tile coordinates, which lost the sign of such a sliver
/// far from the tile's origin (a z6 tile stopped the parse on it).
final class ParseLineClipWindingTests: XCTestCase {
    func testAClippedRibbonWithGentleJoinsKeepsItsWinding() throws {
        var checked = 0
        for step in 1 ... 40 {
            // A line far from the origin, bending by a hair at every node,
            // that leaves the tile, so the whole ribbon takes the clip.
            let bend = Float(step) * 0.0004
            var points: [SIMD2<Float>] = []
            var position = SIMD2<Float>(1900, 263)
            var heading: Float = 0.2
            for _ in 0 ..< 40 {
                points.append(position)
                heading += bend
                position += SIMD2<Float>(cos(heading), sin(heading)) * 61.7
            }
            points.append(SIMD2<Float>(4300, 263))
            let ribbon = try XCTUnwrap(ParseLine().parse(points: points,
                                                         width: 21.92,
                                                         tileExtent: 4096,
                                                         startCapRound: true,
                                                         endCapRound: true,
                                                         lineJoinRound: true))
            XCTAssertTrue(ribbon.lineNormals.isEmpty, "the clipped, pre-extruded path")
            XCTAssertNil(ParsedPolygon.firstClockwiseTriangle(vertices: ribbon.vertices, indices: ribbon.indices),
                         "bend \(bend)")
            checked += 1
        }
        XCTAssertEqual(checked, 40)
    }
}

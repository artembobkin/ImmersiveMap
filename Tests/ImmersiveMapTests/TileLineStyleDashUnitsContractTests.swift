// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The world-locked dash contract between `TileLineStyle` and `Tile.metal`:
/// a style flagged `dashInTileUnits` states its dash period in tile units,
/// and the shader cuts it from arc length WITHOUT the point-to-unit
/// conversion a screen pattern gets. The flag lives in the slot that used to
/// be `reserved0`, so the Swift and Metal structs must agree on it by
/// position as well as by name.
final class TileLineStyleDashUnitsContractTests: XCTestCase {
    func testSwiftAndMetalStructsAgreeOnTheFlagSlot() throws {
        XCTAssertEqual(MemoryLayout<TileLineStyle>.stride, 52)
        XCTAssertEqual(MemoryLayout<TileLineStyle>.offset(of: \.dashInTileUnits), 20,
                       "The flag is the sixth float, the slot that was reserved0")

        let source = try shaderSource("Tile/Shaders/TileShading.h")
        // Field order in the mirror struct: the flag follows minimumWidthPoints.
        let structRange = try XCTUnwrap(source.range(of: "struct LineStyle {"))
        let body = source[structRange.upperBound...]
        let minimum = try XCTUnwrap(body.range(of: "float minimumWidthPoints;"))
        let flag = try XCTUnwrap(body.range(of: "float dashInTileUnits;"))
        XCTAssertLessThan(minimum.lowerBound, flag.lowerBound)
        XCTAssertNil(body[..<flag.lowerBound].range(of: "float reserved"),
                     "No reserved slot may precede the flag: it took reserved0's position")
        // The symbol ceiling took reserved1's slot, right after the flag.
        XCTAssertEqual(MemoryLayout<TileLineStyle>.offset(of: \.maximumWidthPoints), 24)
        let ceiling = try XCTUnwrap(body.range(of: "float maximumWidthPoints;"))
        XCTAssertLessThan(flag.lowerBound, ceiling.lowerBound)
        // The world lock zoom is the ninth float, after the half-width.
        XCTAssertEqual(MemoryLayout<TileLineStyle>.offset(of: \.worldLockZoom), 32)
        let halfWidth = try XCTUnwrap(body.range(of: "float halfWidthUnits;"))
        let worldLock = try XCTUnwrap(body.range(of: "float worldLockZoom;"))
        XCTAssertLessThan(halfWidth.lowerBound, worldLock.lowerBound)
        // The zoom ramp follows, four floats in the mirror's order.
        XCTAssertEqual(MemoryLayout<TileLineStyle>.offset(of: \.rampStartWidthPoints), 36)
        XCTAssertEqual(MemoryLayout<TileLineStyle>.offset(of: \.rampStartAlpha), 48)
        var cursor = worldLock.upperBound
        for field in ["float rampStartWidthPoints;", "float rampStartZoom;", "float rampEndZoom;",
                      "float rampStartAlpha;"] {
            let range = try XCTUnwrap(body.range(of: field, range: cursor ..< body.endIndex), field)
            cursor = range.upperBound
        }
    }

    func testShaderSkipsThePointConversionForWorldLockedDashes() throws {
        let shared = try shaderSource("Tile/Shaders/TileShading.h")
        // The unit scale is 1 for a world-locked pattern and the draw's
        // unitsPerPoint otherwise; both dash and gap must use it.
        XCTAssertTrue(shared.contains("dashInTileUnits > 0.5h ? 1.0 : dashUnitsPerPoint"))
        XCTAssertTrue(shared.contains("float dashUnits = float(dashLengthPoints) * unitScale;"))
        XCTAssertTrue(shared.contains("float gapUnits = float(lineStyle.w) * unitScale;"))
        // The flag no longer travels vertex to fragment: the lines-class
        // fragment resolves the style by index and derives the flag from
        // the style buffer itself, on the plane and on the sphere alike
        // (both fragments call tileLineFragmentColor).
        XCTAssertTrue(shared.contains("lineStyle.dashInTileUnits > 0.0 ? 1.0h : 0.0h,"))
        let flat = try shaderSource("Tile/Shaders/Tile.metal")
        XCTAssertTrue(flat.contains("tileLineFragmentColor(in.styleIndex, in.lineDistance, in.lineParameterRaw,"))
        let sphere = try shaderSource("Tile/Shaders/TileSphere.metal")
        XCTAssertTrue(sphere.contains("tileLineFragmentColor(in.styleIndex, in.lineDistance, in.lineParameterRaw,"))
    }

    func testParserBakesTheFlagIntoTheGPUStyle() {
        let flagged = LinePass(key: 1,
                               color: SIMD4<Float>(1, 1, 1, 1),
                               lineWidthPoints: 1,
                               dashLengthPoints: 40,
                               dashGapPoints: 80,
                               dashInTileUnits: true,
                               lineGeometry: LineGeometryStyle(lineWidth: 8))
        let plain = LinePass(key: 2,
                             color: SIMD4<Float>(1, 1, 1, 1),
                             lineWidthPoints: 1,
                             dashLengthPoints: 7,
                             dashGapPoints: 3.5,
                             lineGeometry: LineGeometryStyle(lineWidth: 8))
        XCTAssertEqual(TileUnificationStage.makeTileLineStyle(from: flagged).dashInTileUnits, 1)
        XCTAssertEqual(TileUnificationStage.makeTileLineStyle(from: plain).dashInTileUnits, 0)
        // A line style keeps the flag on its one stroke too.
        XCTAssertTrue(FeatureStyle.line(LineStyle(pass: flagged)).resolvedLineRenderPasses[0].dashInTileUnits)
        XCTAssertFalse(FeatureStyle.line(LineStyle(pass: plain)).resolvedLineRenderPasses[0].dashInTileUnits)
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

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
        XCTAssertEqual(MemoryLayout<TileLineStyle>.stride, 32)
        XCTAssertEqual(MemoryLayout<TileLineStyle>.offset(of: \.dashInTileUnits), 20,
                       "The flag is the sixth float, the slot that was reserved0")

        let source = try shaderSource("Render/Tiles/Shaders/TileShading.h")
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
    }

    func testShaderSkipsThePointConversionForWorldLockedDashes() throws {
        let shared = try shaderSource("Render/Tiles/Shaders/TileShading.h")
        // The unit scale is 1 for a world-locked pattern and the draw's
        // unitsPerPoint otherwise; both dash and gap must use it.
        XCTAssertTrue(shared.contains("dashInTileUnits > 0.5h ? 1.0 : dashUnitsPerPoint"))
        XCTAssertTrue(shared.contains("float dashUnits = float(dashLengthPoints) * unitScale;"))
        XCTAssertTrue(shared.contains("float gapUnits = float(lineStyle.w) * unitScale;"))
        // The flag travels vertex to fragment, on the plane and on the sphere.
        XCTAssertTrue(shared.contains("out.lineDashInTileUnits = lineStyle.dashInTileUnits > 0.0 ? 1.0h : 0.0h;"))
        for shader in ["Render/Tiles/Shaders/Tile.metal", "Render/Tiles/Shaders/TileSphere.metal"] {
            let source = try shaderSource(shader)
            XCTAssertTrue(source.contains("out.lineDashInTileUnits = style.lineDashInTileUnits;"), shader)
            XCTAssertTrue(source.contains("style.lineDashInTileUnits = in.lineDashInTileUnits;"), shader)
        }
    }

    func testParserBakesTheFlagIntoTheGPUStyle() {
        let flagged = FeatureStyle(key: 1,
                                   color: SIMD4<Float>(1, 1, 1, 1),
                                   lineWidthPoints: 1,
                                   dashLengthPoints: 40,
                                   dashGapPoints: 80,
                                   dashInTileUnits: true,
                                   parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 8))
        let plain = FeatureStyle(key: 2,
                                 color: SIMD4<Float>(1, 1, 1, 1),
                                 lineWidthPoints: 1,
                                 dashLengthPoints: 7,
                                 dashGapPoints: 3.5,
                                 parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 8))
        XCTAssertEqual(TileMvtParser.makeTileLineStyle(from: flagged).dashInTileUnits, 1)
        XCTAssertEqual(TileMvtParser.makeTileLineStyle(from: plain).dashInTileUnits, 0)
        // The synthesized single pass keeps the flag too.
        XCTAssertTrue(flagged.resolvedLineRenderPasses[0].dashInTileUnits)
        XCTAssertFalse(plain.resolvedLineRenderPasses[0].dashInTileUnits)
    }

    private func shaderSource(_ relativePath: String) throws -> String {
        let packageRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRootURL.appendingPathComponent("ImmersiveMap").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

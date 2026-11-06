// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The label styles the shaders read, laid out alike in Swift and in Metal:
/// the screen labels' `TextStyle` (TextShader.metal) and the surface labels'
/// `SurfaceLabelDraw` (SurfaceLabel.metal). A field one side has and the
/// other lacks shifts every field after it, and the label draws with the
/// wrong halo or none, with nothing to say why. And the built-in style's
/// labels are laid over the map softly.
final class LabelStyleUniformLayoutTests: XCTestCase {
    func testTheScreenLabelStyleMatchesTheShader() throws {
        XCTAssertEqual(MemoryLayout<TextStyleUniform>.stride, 64)
        XCTAssertEqual(MemoryLayout<TextStyleUniform>.offset(of: \.opacity), 52)
        XCTAssertEqual(MemoryLayout<TextStyleUniform>.offset(of: \.haloSoftness), 56)
        XCTAssertEqual(try fields(of: "TextStyle", in: "Text/Shaders/TextShader.metal"),
                       ["float3 textColor", "float fillBiasPx", "float3 strokeColor", "float strokeWidthPx",
                        "float opacity", "float haloSoftness"])
    }

    func testTheSurfaceLabelDrawMatchesTheShader() throws {
        XCTAssertEqual(MemoryLayout<SurfaceLabelDrawUniform>.stride, 64)
        XCTAssertEqual(MemoryLayout<SurfaceLabelDrawUniform>.offset(of: \.haloSoftness), 60)
        XCTAssertEqual(try fields(of: "SurfaceLabelDraw", in: "Labels/Shaders/Surface/SurfaceLabel.metal"),
                       ["float4 fillColor", "float4 strokeColor", "float haloAtlasTexels", "float depth",
                        "float haloPass", "float tileUnitsPerPoint", "float2 viewportSizePx",
                        "float pixelsPerPoint", "float haloSoftness"])
    }

    /// The names are a little transparent and their halos fade out, the
    /// countries and the regions lighter still. The water's names wear no
    /// halo to soften.
    func testTheBuiltInLabelsAreLaidOverTheMapSoftly() {
        let labels = ProtomapsBasemapTheme.LabelStyles.default
        for (name, appearance) in [("city", labels.city), ("town", labels.town), ("district", labels.district),
                                   ("poi", labels.poi), ("road", labels.road)] {
            XCTAssertEqual(appearance.opacity, 0.85, name)
            XCTAssertEqual(appearance.haloSoftness, 0.5, name)
        }
        XCTAssertEqual(labels.water.opacity, 0.85)
        XCTAssertEqual(labels.country.opacity, 0.65)
        XCTAssertEqual(labels.country.haloSoftness, 0.5)
        XCTAssertEqual(labels.region.opacity, 0.7)
        XCTAssertEqual(labels.region.haloSoftness, 0.5)
        XCTAssertEqual(LabelTextStyle(fillColor: .zero, strokeColor: .one, haloEm: 0.1,
                                      sizePoints: 12, weight: .bold).haloSoftness, 0,
                       "A style that names no softness keeps a halo solid to its edge")
    }

    /// The fields of a struct of a shader, in order, without their comments.
    private func fields(of structName: String, in relativePath: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ImmersiveMap")
            .appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct \(structName) {"))
        let body = source[start.upperBound...].prefix { $0 != "}" }
        return body.split(separator: "\n")
            .map { line in
                let code = line.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                return code.trimmingCharacters(in: .whitespaces)
            }
            .filter { $0.isEmpty == false }
            .map { $0.hasSuffix(";") ? String($0.dropLast()) : $0 }
    }
}

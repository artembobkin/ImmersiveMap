// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest

final class TextShaderStrokeClampTests: XCTestCase {
    func testShaderUsesTriplePrecisionTextAtlasRange() throws {
        let source = try textShaderSource()

        XCTAssertFalse(source.contains("float2(8.0)"))
        XCTAssertFalse(source.contains("const float distanceRange = 8.0"))
        XCTAssertTrue(source.contains("const float distanceRange = 24.0"))
        XCTAssertTrue(source.contains("float2(distanceRange)"))
    }

    func testShaderUsesMtsdfAlphaForStrokeDistance() throws {
        let source = try textShaderSource()

        XCTAssertTrue(source.contains("atlasSample.a"))
        XCTAssertTrue(source.contains("sdfPxDist"))
        XCTAssertTrue(source.contains("half outer = half(smoothstep(-strokeWidthPx - 0.5, -strokeWidthPx + 0.5, distance.sdfPxDist));"))
    }

    /// A class that asks for no halo (the POIs) must get none: fill and outer
    /// edge come from two different distance fields, so their difference at
    /// zero width is not reliably zero.
    func testAZeroWidthStrokeIsSkippedRatherThanDifferenced() throws {
        let source = try textShaderSource()

        XCTAssertTrue(source.contains("half stroke = strokeWidthPx > 0.0 ? clamp(outer - fill, 0.0h, 1.0h) : 0.0h;"))
    }

    func testBaseTextFragmentCapsStrokeBeforeItFillsGlyphQuad() throws {
        let source = try textShaderSource()
        let baseFragmentSource = try XCTUnwrap(source.components(separatedBy: "fragment TextFragmentOut roadTextFragment").first)

        XCTAssertFalse(baseFragmentSource.contains("max(distance.screenPxRange - 0.75, 0.75)"))
        XCTAssertTrue(baseFragmentSource.contains("max(0.5 * distance.screenPxRange - 0.5, 0.0)"))
    }

    private func textShaderSource() throws -> String {
        try shaderSource("Render/Text/Shaders/TextShader.metal")
    }

    private func shaderSource(_ relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shaderURL = packageRootURL.appendingPathComponent("ImmersiveMap/" + relativePath)
        return try String(contentsOf: shaderURL, encoding: .utf8)
    }

    /// A hidden label (lost its collision, a duplicate, faded out, beyond
    /// the horizon) leaves the clip volume in the vertex stage, so the
    /// rasterizer drops it whole: alpha 0 alone would still shade every
    /// fragment of its quads.
    func testHiddenLabelsLeaveTheClipVolumeInsteadOfDrawingTransparent() throws {
        let common = try shaderSource("Render/Labels/Shaders/Shared/LabelTextCommon.h")
        XCTAssertTrue(common.contains("static inline float4 hiddenLabelClipPosition()"))
        XCTAssertTrue(common.contains("return float4(-2.0, -2.0, 0.0, 1.0);"),
                      "Outside the volume on one side: a whole quad there is trivially rejected")
        for path in ["Render/Labels/Shaders/Base/LabelTextVertex.metal",
                     "Render/Labels/Shaders/Road/RoadLabelTextVertex.metal",
                     "Render/Labels/Shaders/POI/PoiSprite.metal"] {
            let source = try shaderSource(path)
            XCTAssertTrue(source.contains("if (!isVisible) {\n        out.position = hiddenLabelClipPosition();"),
                          "\(path) must move a hidden label out of the clip volume")
            XCTAssertTrue(source.contains("fadeAlpha > 0.0"),
                          "\(path): a label faded to nothing is hidden too")
        }
    }

    /// One text pass: the fragment writes a depth that orders fill over
    /// halo across neighbouring glyph quads, both just short of the far
    /// plane the labels rasterize at, so the model occlusion prepass still
    /// clips them.
    func testTextFragmentsOrderFillOverHaloThroughDepth() throws {
        let source = try textShaderSource()
        XCTAssertTrue(source.contains("float depth [[depth(less)]];"))
        XCTAssertTrue(source.contains("constant float kLabelFillDepth = 0.99999976;"))
        XCTAssertTrue(source.contains("constant float kLabelHaloDepth = 0.99999988;"))
        XCTAssertTrue(source.contains("out.depth = fill > 0.0h ? kLabelFillDepth : (stroke > 0.0h ? kLabelHaloDepth : 1.0);"))
        XCTAssertTrue(source.contains("fragment TextFragmentOut textFragment("))
        XCTAssertTrue(source.contains("fragment TextFragmentOut roadTextFragment("))
        let fill = Float(0.99999976), halo = Float(0.99999988)
        XCTAssertLessThan(fill, halo, "The fill is nearer, so a later halo fails lessEqual against it")
        XCTAssertLessThan(halo, 1.0, "and a later fill still passes over a halo and over the far plane")
        XCTAssertNotEqual(fill, halo, "Distinct in Float32")
    }
}

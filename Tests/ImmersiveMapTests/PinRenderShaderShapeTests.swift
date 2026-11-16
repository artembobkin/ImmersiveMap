// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import XCTest

final class PinRenderShaderShapeTests: XCTestCase {
    func testPinFragmentMorphsBetweenPinSDFAndBodyCircle() throws {
        let source = try shaderSource(named: "PinRender.metal")

        // The shape always starts from the baked distance field and morphs
        // into the analytic body circle by per-instance morph. The masks
        // below read only the blended distance.
        XCTAssertTrue(source.contains("decodeSignedDistanceTexels"))
        XCTAssertTrue(source.contains("sdfTexture.sample"))
        XCTAssertTrue(source.contains("float circleDistanceTexels"))
        XCTAssertTrue(source.contains("mix(pinDistanceTexels, circleDistanceTexels, saturate(in.morph))"))
        XCTAssertFalse(source.contains("smoothstep(-edgeWidthTexels, edgeWidthTexels, pinDistanceTexels)"))
    }

    func testBadgeVerticesApplyPerPinScreenSizeScale() throws {
        let source = try shaderSource(named: "PinRender.metal")

        XCTAssertTrue(source.contains("instance.screenSizeScale"))
        XCTAssertTrue(source.contains("style.sizePx.x * screenSizeScale"))
        XCTAssertTrue(source.contains("style.originXPx * screenSizeScale"))
    }

    func testBadgeFragmentsApplyCompressionContentAlpha() throws {
        let source = try shaderSource(named: "PinRender.metal")

        XCTAssertTrue(source.contains("out.contentAlpha = instance.contentAlpha"))
        XCTAssertTrue(source.contains("color.a *= half(in.visibilityAlpha * in.contentAlpha)"))
    }

    func testPinFragmentsApplyScreenPointVisibilityAlpha() throws {
        let source = try shaderSource(named: "PinRender.metal")

        XCTAssertTrue(source.contains("out.visibilityAlpha = point.visibilityAlpha"))
        XCTAssertTrue(source.contains("color.a * half(in.visibilityAlpha)"))
        XCTAssertTrue(source.contains("picture.a * half(in.visibilityAlpha)"))
    }

    func testBeamShaderStartsAtTrueAnchorAndFollowsCompression() throws {
        let source = try shaderSource(named: "PinBeam.metal")

        // A cone with the apex at the true geo point and the base at the
        // circle's tangent points ("edge to edge"); it fades in by the anchor
        // offset length, so only displaced circles get the ray.
        XCTAssertTrue(source.contains("float2 anchor = point.position;"))
        XCTAssertTrue(source.contains("style.pinCenterOffsetPx * offset.scale"))
        XCTAssertTrue(source.contains("style.pinBodyHalfMinPx * offset.scale"))
        XCTAssertTrue(source.contains("float2 tangentLeft"))
        XCTAssertTrue(source.contains("float2 tangentRight"))
        XCTAssertTrue(source.contains("* point.visibilityAlpha"))
        XCTAssertTrue(source.contains("beamReveal(length(offset.value))"))
        // The ray fades out as it approaches the actual geo point.
        XCTAssertTrue(source.contains("taper = taper * sqrt(taper);"))
        // No anchor dots at the geo positions: the cone only.
        XCTAssertFalse(source.contains("pinAnchorDotVertex"))
    }

    private func shaderSource(named name: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shaderURL = packageRootURL.appendingPathComponent("Sources/ImmersiveMap/Pins/Shaders/\(name)")
        return try String(contentsOf: shaderURL, encoding: .utf8)
    }
}

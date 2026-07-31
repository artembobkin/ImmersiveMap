// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest

final class AvatarRenderShaderShapeTests: XCTestCase {
    func testAvatarFragmentMorphsBetweenMarkerSDFAndBodyCircle() throws {
        let source = try shaderSource(named: "AvatarRender.metal")

        // The shape always starts from the MTSDF pin and morphs into the
        // analytic body circle by per-instance morph; the masks below read only the blended SDF.
        XCTAssertTrue(source.contains("decodeSignedDistanceTexels"))
        XCTAssertTrue(source.contains("sdfTexture.sample"))
        XCTAssertTrue(source.contains("float circleDistanceTexels"))
        XCTAssertTrue(source.contains("mix(markerDistanceTexels, circleDistanceTexels, saturate(in.morph))"))
        XCTAssertFalse(source.contains("smoothstep(-edgeWidthTexels, edgeWidthTexels, markerDistanceTexels)"))
    }

    func testBadgeVerticesApplyPerAvatarScreenSizeScale() throws {
        let source = try shaderSource(named: "AvatarRender.metal")

        XCTAssertTrue(source.contains("instance.screenSizeScale"))
        XCTAssertTrue(source.contains("style.sizePx.x * screenSizeScale"))
        XCTAssertTrue(source.contains("style.originXPx * screenSizeScale"))
    }

    func testBadgeFragmentsApplyCompressionContentAlpha() throws {
        let source = try shaderSource(named: "AvatarRender.metal")

        XCTAssertTrue(source.contains("out.contentAlpha = instance.contentAlpha"))
        XCTAssertTrue(source.contains("color.a *= in.visibilityAlpha * in.contentAlpha"))
    }

    func testAvatarFragmentsApplyScreenPointVisibilityAlpha() throws {
        let source = try shaderSource(named: "AvatarRender.metal")

        XCTAssertTrue(source.contains("out.visibilityAlpha = point.visibilityAlpha"))
        XCTAssertTrue(source.contains("color.a = alpha * in.visibilityAlpha"))
    }

    func testBeamShaderStartsAtTrueAnchorAndFollowsCompression() throws {
        let source = try shaderSource(named: "AvatarBeam.metal")

        // A cone with the apex at the true geo point and the base at the
        // circle's tangent points ("edge to edge"); it fades in by the anchor
        // offset length, so only displaced circles get the ray.
        XCTAssertTrue(source.contains("float2 anchor = point.position;"))
        XCTAssertTrue(source.contains("style.markerCenterOffsetPx * offset.scale"))
        XCTAssertTrue(source.contains("style.markerBodyHalfMinPx * offset.scale"))
        XCTAssertTrue(source.contains("float2 tangentLeft"))
        XCTAssertTrue(source.contains("float2 tangentRight"))
        XCTAssertTrue(source.contains("* point.visibilityAlpha"))
        XCTAssertTrue(source.contains("beamReveal(length(offset.value))"))
        // The ray fades out as it approaches the actual geo point.
        XCTAssertTrue(source.contains("float taper = in.taper * in.taper * in.taper;"))
        // No anchor dots at the geo positions: the cone only.
        XCTAssertFalse(source.contains("avatarAnchorDotVertex"))
    }

    private func shaderSource(named name: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shaderURL = packageRootURL.appendingPathComponent("ImmersiveMap/Render/Avatars/Shaders/\(name)")
        return try String(contentsOf: shaderURL, encoding: .utf8)
    }
}

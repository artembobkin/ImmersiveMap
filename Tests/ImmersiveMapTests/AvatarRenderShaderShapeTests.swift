// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest

final class AvatarRenderShaderShapeTests: XCTestCase {
    func testAvatarFragmentMorphsBetweenMarkerSDFAndBodyCircle() throws {
        let source = try shaderSource(named: "AvatarRender.metal")

        // Форма всегда стартует с MTSDF-пина и морфится в аналитический круг
        // тела по per-instance morph; маски ниже читают только смешанный SDF.
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

        // Конус с вершиной в истинной геоточке и основанием на касательных
        // точках кружка («от края до края»); проявление - по длине смещения
        // якоря, поэтому луч есть только у сдвинутых кружочков.
        XCTAssertTrue(source.contains("float2 anchor = point.position;"))
        XCTAssertTrue(source.contains("style.markerCenterOffsetPx * offset.scale"))
        XCTAssertTrue(source.contains("style.markerBodyHalfMinPx * offset.scale"))
        XCTAssertTrue(source.contains("float2 tangentLeft"))
        XCTAssertTrue(source.contains("float2 tangentRight"))
        XCTAssertTrue(source.contains("* point.visibilityAlpha"))
        XCTAssertTrue(source.contains("beamReveal(length(offset.value))"))
        // Луч затухает при приближении к фактической геоточке.
        XCTAssertTrue(source.contains("float taper = in.taper * in.taper * in.taper;"))
        // Точек-якорей на геопозициях нет: только конус.
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

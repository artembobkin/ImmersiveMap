// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// Value-level contract of transparent space: the setting, how it reaches the
/// frame clear color, and how it is applied to a live map.
final class TransparentSpaceSettingsTests: XCTestCase {
    func testSpaceIsOpaqueByDefault() {
        XCTAssertFalse(ImmersiveMapSettings.default.scene.space.isTransparent)
    }

    func testTransparentSpaceModifierSetsTheFlag() {
        XCTAssertTrue(ImmersiveMapSettings.default.transparentSpace().scene.space.isTransparent)
        XCTAssertFalse(ImmersiveMapSettings.default.transparentSpace(false).scene.space.isTransparent)
    }

    /// The whole point of the mode: the globe pass starts from a fully
    /// transparent pixel, not from a black one, and the configured space color
    /// no longer matters.
    func testTransparentSpaceClearsToATransparentPixel() {
        let settings = ImmersiveMapSettings.default.transparentSpace()
        let clearColor = RenderFrameClearColor.make(transition: 0, settings: settings)

        XCTAssertEqual(clearColor.red, 0)
        XCTAssertEqual(clearColor.green, 0)
        XCTAssertEqual(clearColor.blue, 0)
        XCTAssertEqual(clearColor.alpha, 0)
    }

    func testOpaqueSpaceKeepsItsConfiguredClearColor() {
        var settings = ImmersiveMapSettings.default
        settings.scene.space.clearColor = SIMD4<Double>(0.1, 0.2, 0.3, 1.0)
        let clearColor = RenderFrameClearColor.make(transition: 0, settings: settings)

        XCTAssertEqual(clearColor.red, 0.1, accuracy: 1e-9)
        XCTAssertEqual(clearColor.green, 0.2, accuracy: 1e-9)
        XCTAssertEqual(clearColor.blue, 0.3, accuracy: 1e-9)
        XCTAssertEqual(clearColor.alpha, 1.0, accuracy: 1e-9)
    }

    /// The flat map covers the viewport, so the transition has to arrive at the
    /// opaque map color; halfway there the value stays premultiplied, otherwise
    /// the compositor tints the app background with the un-multiplied color.
    func testTransparentSpaceReachesTheOpaqueMapColorThroughTheTransition() {
        var settings = ImmersiveMapSettings.default.transparentSpace()
        settings.scene.mapClearColor = SIMD4<Double>(1.0, 1.0, 1.0, 1.0)

        let mid = RenderFrameClearColor.make(transition: 0.5, settings: settings)
        XCTAssertEqual(mid.red, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mid.alpha, 0.5, accuracy: 1e-9)

        let flat = RenderFrameClearColor.make(transition: 1.0, settings: settings)
        XCTAssertEqual(flat.red, 1.0, accuracy: 1e-9)
        XCTAssertEqual(flat.alpha, 1.0, accuracy: 1e-9)
    }

    /// The mode is a per-frame uniform and a pass-plan flag, so switching it
    /// must not throw away tile caches or the renderer.
    func testSwitchingTheModeAppliesLive() {
        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: .default,
                                                                   to: .default.transparentSpace())

        XCTAssertTrue(plan.changedDomains.contains(.scene))
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    /// Alpha must accumulate on a transparent destination: `.sourceAlpha` on the
    /// alpha channel squares the coverage, which shows up as washed-out labels,
    /// avatars and routes over the app's own background.
    func testNoPipelineSquaresAlphaCoverage() throws {
        let sourceRoot = packageRootURL().appendingPathComponent("ImmersiveMap")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sourceRoot,
                                                                      includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("sourceAlphaBlendFactor = .sourceAlpha") {
                offenders.append(url.lastPathComponent)
            }
        }

        XCTAssertEqual(offenders, [])
    }

    private func packageRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

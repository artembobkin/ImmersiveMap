// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest

final class RendererLabelDrawerPassTests: XCTestCase {
    /// The text draws once per run: the fragment stage shades the fill and
    /// the halo together from the two distance fields, so an outline pass
    /// under a fill pass only doubled the fragments. The halo reaches the
    /// shader in device pixels, resolved from the style's em ratio and the
    /// frame's scale: the shader's own math is derivative-based and genuinely
    /// pixel-space, so this conversion has to happen here and nowhere else.
    func testBaseAndRoadLabelsDrawFillAndHaloInOnePass() throws {
        let source = try rendererLabelDrawerSource()
        XCTAssertNil(source.range(of: "pass: .outline"))
        XCTAssertNil(source.range(of: "pass: .fill"))
        XCTAssertEqual(source.components(separatedBy: "strokeWidthPx: style.haloWidthPixels(screenScale: screenScale)").count - 1, 2,
                       "The base and the road text each bind the halo width once")
        XCTAssertEqual(source.components(separatedBy: "textColor: style.fillColor").count - 1, 2)
        XCTAssertEqual(source.components(separatedBy: "strokeColor: style.strokeColor").count - 1, 2)
        XCTAssertNil(source.range(of: "strokeWidthPx: 0.0"), "No fill-only pass remains")
    }

    private func rendererLabelDrawerSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL.appendingPathComponent("ImmersiveMap/Render/Labels/Drawers/RendererLabelDrawer.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

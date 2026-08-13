// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest

final class RendererLabelDrawerPassTests: XCTestCase {
    func testBaseLabelsDrawOutlineBeforeFill() throws {
        let source = try rendererLabelDrawerSource()
        let baseDrawSource = try XCTUnwrap(source.components(separatedBy: "static func drawRoadLabels").first)

        XCTAssertTrue(baseDrawSource.contains("pass: .outline"))
        XCTAssertTrue(baseDrawSource.contains("pass: .fill"))
        // The halo reaches the shader in device pixels, resolved from the
        // style's em ratio and the frame's scale. The shader's own math is
        // derivative-based and genuinely pixel-space, so this conversion has to
        // happen here and nowhere else.
        XCTAssertTrue(source.contains("strokeWidthPx: style.haloWidthPixels(screenScale: screenScale)"))
        XCTAssertTrue(source.contains("textColor: style.fillColor"))
        XCTAssertTrue(source.contains("strokeWidthPx: 0.0"))
        let outlineRange = try XCTUnwrap(baseDrawSource.range(of: "pass: .outline"))
        let fillRange = try XCTUnwrap(baseDrawSource.range(of: "pass: .fill"))
        XCTAssertLessThan(baseDrawSource.distance(from: baseDrawSource.startIndex, to: outlineRange.lowerBound),
                          baseDrawSource.distance(from: baseDrawSource.startIndex, to: fillRange.lowerBound))
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

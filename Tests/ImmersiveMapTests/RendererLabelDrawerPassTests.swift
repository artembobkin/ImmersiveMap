// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest

final class RendererLabelDrawerPassTests: XCTestCase {
    func testBaseLabelsDrawOutlineBeforeFill() throws {
        let source = try rendererLabelDrawerSource()
        let baseDrawSource = try XCTUnwrap(source.components(separatedBy: "static func drawRoadLabels").first)

        XCTAssertTrue(baseDrawSource.contains("pass: .outline"))
        XCTAssertTrue(baseDrawSource.contains("pass: .fill"))
        XCTAssertTrue(source.contains("strokeWidthPx: style.strokeWidthPx"))
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

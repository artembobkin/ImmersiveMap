// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import XCTest

final class PinRendererFrameBufferIsolationTests: XCTestCase {
    func testPinPerFrameRenderBuffersUseFrameSlots() throws {
        // cwd on the iOS simulator points into the sandbox; derive the package root from this file's path.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ImmersiveMap/Pins/PinsRenderer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let perFrameStores = [
            "instanceBufferStore",
            "screenPointBufferStore",
            "countBadgeInstanceBufferStore",
            "beamAnchorBufferStore",
            "beamOffsetBufferStore"
        ]

        for store in perFrameStores {
            XCTAssertTrue(source.contains("private let \(store): FrameSlottedDynamicMetalBuffer"),
                          "\(store) must be isolated per in-flight frame slot.")
        }
    }
}

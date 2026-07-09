// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest

final class AvatarRendererFrameBufferIsolationTests: XCTestCase {
    func testAvatarPerFrameRenderBuffersUseFrameSlots() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ImmersiveMap/Render/Avatars/AvatarsRenderer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let perFrameStores = [
            "instanceBufferStore",
            "screenPointBufferStore",
            "clusterInstanceBufferStore",
            "clusterScreenPointBufferStore",
            "batteryBadgeInstanceBufferStore",
            "speedBadgeInstanceBufferStore"
        ]

        for store in perFrameStores {
            XCTAssertTrue(source.contains("private let \(store): FrameSlottedDynamicMetalBuffer"),
                          "\(store) must be isolated per in-flight frame slot.")
        }
    }
}

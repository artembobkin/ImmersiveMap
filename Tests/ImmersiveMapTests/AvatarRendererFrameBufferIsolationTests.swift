// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest

final class AvatarRendererFrameBufferIsolationTests: XCTestCase {
    func testAvatarPerFrameRenderBuffersUseFrameSlots() throws {
        // cwd на iOS-симуляторе указывает в песочницу; корень пакета выводим из пути этого файла.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ImmersiveMap/Render/Avatars/AvatarsRenderer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let perFrameStores = [
            "instanceBufferStore",
            "screenPointBufferStore",
            "batteryBadgeInstanceBufferStore",
            "speedBadgeInstanceBufferStore",
            "beamAnchorBufferStore",
            "beamOffsetBufferStore"
        ]

        for store in perFrameStores {
            XCTAssertTrue(source.contains("private let \(store): FrameSlottedDynamicMetalBuffer"),
                          "\(store) must be isolated per in-flight frame slot.")
        }
    }
}

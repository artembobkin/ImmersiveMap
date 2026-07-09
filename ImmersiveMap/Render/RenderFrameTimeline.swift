// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct RenderFrameTimeline {
    private let startDate = Date()
    private var frameIndex: UInt64 = 0
    private var previousFrameTime: TimeInterval = 0

    mutating func nextFrame() -> RenderFrameTick {
        let nowTime = Date().timeIntervalSince(startDate)
        frameIndex &+= 1

        let deltaTime = frameIndex <= 1 ? 0 : nowTime - previousFrameTime
        previousFrameTime = nowTime

        return RenderFrameTick(index: frameIndex,
                               time: nowTime,
                               deltaTime: deltaTime)
    }
}

struct RenderFrameTick {
    let index: UInt64
    let time: TimeInterval
    let deltaTime: TimeInterval
}

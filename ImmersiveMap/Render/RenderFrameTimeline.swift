// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Source of per-frame scene time (`FrameContext.time`/`deltaTime`) and the
/// wall date stamped into `FrameContextServices.now` (sun position).
///
/// The default is `RenderFrameWallClock`; the offline video export injects a
/// scripted clock so scene time follows the export timeline instead of real time.
protocol RenderFrameClock: AnyObject {
    /// Produces the next frame tick. Implementations must increment the frame
    /// index on every call: per-frame bookkeeping (fade tracking, the resource
    /// registry) relies on unique, monotonically growing indices.
    func nextFrameTick() -> RenderFrameTick
    /// The date associated with the frame being built.
    func currentDate() -> Date
}

/// Default clock: real elapsed time since creation, real current date.
final class RenderFrameWallClock: RenderFrameClock {
    private var timeline = RenderFrameTimeline()

    func nextFrameTick() -> RenderFrameTick {
        timeline.nextFrame()
    }

    func currentDate() -> Date {
        Date()
    }
}

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

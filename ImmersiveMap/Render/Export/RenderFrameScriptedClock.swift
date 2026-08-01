// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Deterministic clock for the offline video export path.
///
/// Scene time advances only via `setTime`; repeated ticks at the held time
/// yield `deltaTime == 0` (settle re-renders must not progress fades or
/// retention), while the frame index keeps incrementing on every tick so
/// per-frame bookkeeping stays valid. The date is fixed by the caller, keeping
/// the earth scene (sun position) deterministic across the whole export.
final class RenderFrameScriptedClock: RenderFrameClock {
    private var frameIndex: UInt64 = 0
    private var currentTime: TimeInterval = 0
    private var previousTickTime: TimeInterval?
    private var date: Date

    init(date: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.date = date
    }

    /// Moves scene time to `time`. Never call with a value earlier than the
    /// previously set one — the export timeline is monotonic.
    func setTime(_ time: TimeInterval) {
        currentTime = time
    }

    func setDate(_ date: Date) {
        self.date = date
    }

    func nextFrameTick() -> RenderFrameTick {
        frameIndex &+= 1
        let deltaTime = previousTickTime.map { currentTime - $0 } ?? 0
        previousTickTime = currentTime
        return RenderFrameTick(index: frameIndex,
                               time: currentTime,
                               deltaTime: deltaTime)
    }

    func currentDate() -> Date {
        date
    }
}

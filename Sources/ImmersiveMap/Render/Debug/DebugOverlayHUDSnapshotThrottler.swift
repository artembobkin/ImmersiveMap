// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct DebugOverlayHUDSnapshotThrottler {
    static let defaultMinimumInterval: TimeInterval = 0.2

    private let minimumInterval: TimeInterval
    private var lastPublishTime: TimeInterval?

    init(minimumInterval: TimeInterval = Self.defaultMinimumInterval) {
        self.minimumInterval = max(0, minimumInterval)
    }

    mutating func shouldBuildSnapshot(isEnabled: Bool, at time: TimeInterval) -> Bool {
        guard isEnabled else {
            lastPublishTime = nil
            return false
        }

        return shouldPublish(at: time)
    }

    mutating func shouldPublish(snapshot: DebugOverlayHUDSnapshot?, at time: TimeInterval) -> Bool {
        guard snapshot != nil else {
            lastPublishTime = nil
            return true
        }

        return shouldPublish(at: time)
    }

    private mutating func shouldPublish(at time: TimeInterval) -> Bool {
        guard minimumInterval > 0 else {
            lastPublishTime = time
            return true
        }

        guard let lastPublishTime else {
            self.lastPublishTime = time
            return true
        }

        let elapsed = time - lastPublishTime
        guard elapsed >= minimumInterval || minimumInterval - elapsed <= .ulpOfOne else {
            return false
        }

        self.lastPublishTime = time
        return true
    }
}

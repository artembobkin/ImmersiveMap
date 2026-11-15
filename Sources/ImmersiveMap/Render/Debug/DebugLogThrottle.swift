// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  DebugLogThrottle.swift
//  ImmersiveMap
//

import Foundation

/// Limits repetitive debug logs by a minimum time interval.
struct DebugLogThrottle {
    private let minimumInterval: TimeInterval
    private var lastLogTime: TimeInterval?

    init(minimumInterval: TimeInterval = 1.0) {
        self.minimumInterval = max(0, minimumInterval)
        self.lastLogTime = nil
    }

    mutating func shouldEmitLog(now: TimeInterval) -> Bool {
        guard let lastLogTime else {
            self.lastLogTime = now
            return true
        }

        guard now - lastLogTime >= minimumInterval else {
            return false
        }

        self.lastLogTime = now
        return true
    }
}

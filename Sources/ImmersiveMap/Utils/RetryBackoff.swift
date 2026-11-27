// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// The pause before a failed load is tried again: `base` after the first
/// failure, doubling with each one after it, up to `maximum`. The policy's
/// numbers are the caller's, the curve is one.
enum RetryBackoff {
    static func delay(afterAttempts attempts: Int,
                      base: TimeInterval,
                      maximum: TimeInterval) -> TimeInterval {
        min(maximum, base * pow(2, Double(attempts - 1)))
    }
}

// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// Following a target over time by a half-life: each frame closes a share
/// of the gap that depends on the time passed and not on the frame rate,
/// so a slow frame lands where two fast ones would. The camera's follows,
/// the pan's inertia, the animated zoom and the relief's surroundings all
/// step this way.
enum HalfLifeDecay {
    /// The longest step a frame is taken for. A frame longer than this (a
    /// stall, a return from the background) must not make the follower
    /// jump, so its step is capped.
    static let maximumDeltaTime: CFTimeInterval = 0.05

    /// The frame's time as a step: never negative, never past
    /// `maximumDeltaTime`, and zero for a time that is not a number.
    static func clampedDeltaTime(_ deltaTime: CFTimeInterval) -> CFTimeInterval {
        guard deltaTime.isFinite else {
            return 0
        }

        return min(max(0, deltaTime), maximumDeltaTime)
    }

    /// The share of a gap that is still open after `deltaTime`: a half
    /// after one half-life, a quarter after two. The caller decides what a
    /// half-life of zero means.
    static func remaining(deltaTime: Double, halfLife: Double) -> Double {
        pow(0.5, deltaTime / halfLife)
    }
}

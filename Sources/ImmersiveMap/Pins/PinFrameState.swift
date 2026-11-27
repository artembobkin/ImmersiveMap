// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// What the pins tell the frame (`FrameStateBoard`).
struct PinState {
    static let empty = PinState(hasActiveAnimations: false)

    var hasActiveAnimations: Bool
}

extension PinState: FrameState {
    init() {
        self = .empty
    }
}

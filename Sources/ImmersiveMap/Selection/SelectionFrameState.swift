// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// What the frame drew that a tap can land on (`FrameStateBoard`), one
/// entry from each feature that drew something selectable
/// (`SelectionPickData`). The engine hands it on once the frame reaches the
/// screen, so taps are tested against what is visible.
struct SelectionFrameState: FrameState {
    var pickData: [any SelectionPickData] = []
}

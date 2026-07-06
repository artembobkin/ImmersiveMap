// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

enum RenderInvalidationReason {
    case tileAvailable
    case tileRetryDue
    case externalStateChanged
}

struct RenderActivityState {
    let labelFadeRenderingActive: Bool
    let labelVisibilityCycleRenderingActive: Bool
    let avatarAnimationRenderingActive: Bool
}

protocol RenderFrameEventSink: AnyObject {
    func invalidate(_ reason: RenderInvalidationReason)
    func applyActivityState(_ state: RenderActivityState)
    func updateAvatarSelectionSnapshot(_ snapshot: AvatarSelectionSnapshot)
    func updateDebugOverlayHUDSnapshot(_ snapshot: DebugOverlayHUDSnapshot?)
}

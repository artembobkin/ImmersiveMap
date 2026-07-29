// Copyright (c) 2025-2026 ImmersiveMap contributors.
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

/// События приходят и с main thread, и из фоновых задач (загрузка тайлов,
/// ретраи), поэтому реализации обязаны быть потокобезопасными.
protocol RenderFrameEventSink: AnyObject, Sendable {
    func invalidate(_ reason: RenderInvalidationReason)
    func applyActivityState(_ state: RenderActivityState)
    func updateAvatarSelectionSnapshot(_ snapshot: AvatarSelectionSnapshot)
    func updateDebugOverlayHUDSnapshot(_ snapshot: DebugOverlayHUDSnapshot?)
    /// В отличие от `updateAvatarSelectionSnapshot` (completion handler,
    /// off-main) зовётся синхронно из render-цикла на main thread, чтобы
    /// позиции маркеров применились в той же CA-транзакции, что и кадр.
    func updateMarkerProjectionSnapshot(_ snapshot: MarkerProjectionSnapshot)
}

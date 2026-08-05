// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

enum RenderInvalidationReason {
    case tileAvailable
    case tileRetryDue
    case sceneModelAssetLoaded
    case externalStateChanged
}

struct RenderActivityState {
    let labelFadeRenderingActive: Bool
    let labelVisibilityCycleRenderingActive: Bool
    let avatarAnimationRenderingActive: Bool
    let sceneModelAnimationRenderingActive: Bool
    let routeAnimationRenderingActive: Bool
}

/// Events arrive both from the main thread and from background tasks (tile
/// loading, retries), so implementations must be thread-safe.
protocol RenderFrameEventSink: AnyObject, Sendable {
    func invalidate(_ reason: RenderInvalidationReason)
    func applyActivityState(_ state: RenderActivityState)
    func updateAvatarSelectionSnapshot(_ snapshot: AvatarSelectionSnapshot)
    /// Path animations that ended on the last frame, with where they left the
    /// model.
    func completeSceneModelPathAnimations(_ results: [SceneModelPathAnimationResult])
    func updateDebugOverlayHUDSnapshot(_ snapshot: DebugOverlayHUDSnapshot?)
    /// Unlike `updateAvatarSelectionSnapshot` (completion handler, off-main),
    /// this is called synchronously from the render loop on the main thread so
    /// that marker positions apply in the same CA transaction as the frame.
    func updateMarkerProjectionSnapshot(_ snapshot: MarkerProjectionSnapshot)
}

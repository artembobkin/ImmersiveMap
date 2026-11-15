// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

package enum RenderInvalidationReason {
    case tileAvailable
    case tileRetryDue
    case sceneModelAssetLoaded
    /// A layer of the app's data is ready on the GPU (`LayerMeshStore`).
    case layerDataLoaded
    case externalStateChanged
}

struct RenderActivityState {
    let labelFadeRenderingActive: Bool
    let pinAnimationRenderingActive: Bool
    let sceneModelAnimationRenderingActive: Bool
    /// The buildings or the models rising out of the ground
    /// (`ExtrusionRise`).
    var extrusionRiseRenderingActive: Bool = false
    /// The animated zoom still on its way to the camera's (`AnimatedZoom`).
    var animatedZoomRenderingActive: Bool = false
}

/// Events arrive both from the main thread and from background tasks (tile
/// loading, retries), so implementations must be thread-safe.
protocol RenderFrameEventSink: AnyObject, Sendable {
    func invalidate(_ reason: RenderInvalidationReason)
    func applyActivityState(_ state: RenderActivityState)
    /// What a frame that reached the screen drew that a tap can land on,
    /// one entry from each feature that drew something selectable. Called
    /// from the command buffer's completion handler, off the main thread.
    func updateSelectionPickData(_ pickData: [any SelectionPickData])
    /// Path animations that ended on the last frame, with where they left the
    /// model.
    func completeSceneModelPathAnimations(_ results: [SceneModelPathAnimationResult])
    func updateDebugOverlayHUDSnapshot(_ snapshot: DebugOverlayHUDSnapshot?)
    /// A live source for the HUD's tile list, attached by the engine at
    /// creation and detached (nil) when it is discarded, so the panel can
    /// read the loader's state between frames. Sinks with no HUD ignore it.
    func attachTileLoadingStatus(provider: (@Sendable () -> TileLoadingStatusSnapshot?)?)
    /// The reporter's state moved, from a loader's thread: the panel reads
    /// its rows again between frames. Sinks with no HUD ignore it.
    func tileLoadingStatusDidChange()
    /// What the panel shows, for the frame to build only that. A sink with
    /// no HUD answers everything.
    func debugOverlayHUDContentRequest() -> DebugOverlayHUDContentRequest
    /// Unlike `updateSelectionPickData` (completion handler, off-main),
    /// this is called synchronously from the render loop on the main thread so
    /// that marker positions apply in the same CA transaction as the frame.
    func updateAnnotationProjectionSnapshot(_ snapshot: AnnotationProjectionSnapshot)
    /// The engine feeding this sink is being discarded: what a frame still
    /// in flight on the GPU delivers from here on is dropped, so it cannot
    /// bring back state a successor has just reset. Called on the main
    /// thread. A sink that hands nothing on later ignores it.
    func invalidateDelivery()
}

extension RenderFrameEventSink {
    func attachTileLoadingStatus(provider: (@Sendable () -> TileLoadingStatusSnapshot?)?) {}
    func tileLoadingStatusDidChange() {}
    func debugOverlayHUDContentRequest() -> DebugOverlayHUDContentRequest { .all }
    func invalidateDelivery() {}
}

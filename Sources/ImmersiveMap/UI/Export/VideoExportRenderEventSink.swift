// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// Event sink of the headless export engine.
///
/// Instead of driving a display link, it records what the export loop polls
/// between renders: a "new tiles materialized" flag and the latest scene
/// activity state. Snapshot events (markers, pin selection, debug HUD) have
/// no meaning offscreen and are dropped. Events arrive from background tile
/// tasks and the Metal completion thread, hence the lock.
final class VideoExportRenderEventSink: RenderFrameEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingInvalidation = false
    private var latestActivityState = RenderActivityState(labelFadeRenderingActive: false,
                                                          pinAnimationRenderingActive: false,
                                                          sceneModelAnimationRenderingActive: false)
    private var latestAnnotationProjectionSnapshot: AnnotationProjectionSnapshot?

    /// Latest per-frame activity flags published by the engine.
    var activityState: RenderActivityState {
        lock.withLock { latestActivityState }
    }

    /// Latest marker projection published by the engine, the positions the
    /// export compositor draws SwiftUI annotations at.
    var annotationProjectionSnapshot: AnnotationProjectionSnapshot? {
        lock.withLock { latestAnnotationProjectionSnapshot }
    }

    /// Returns whether an invalidation arrived since the last call, clearing
    /// the flag.
    func consumePendingInvalidation() -> Bool {
        lock.withLock {
            let hadSignal = pendingInvalidation
            pendingInvalidation = false
            return hadSignal
        }
    }

    // MARK: - RenderFrameEventSink

    func invalidate(_ reason: RenderInvalidationReason) {
        lock.withLock { pendingInvalidation = true }
    }

    func applyActivityState(_ state: RenderActivityState) {
        lock.withLock { latestActivityState = state }
    }

    /// Scene models are excluded from export, so no animation can finish here.
    func completeSceneModelPathAnimations(_: [SceneModelPathAnimationResult]) {}

    func updateSelectionPickData(_ pickData: [any SelectionPickData]) {}

    func updateDebugOverlayHUDSnapshot(_ snapshot: DebugOverlayHUDSnapshot?) {}

    func updateAnnotationProjectionSnapshot(_ snapshot: AnnotationProjectionSnapshot) {
        lock.withLock { latestAnnotationProjectionSnapshot = snapshot }
    }
}

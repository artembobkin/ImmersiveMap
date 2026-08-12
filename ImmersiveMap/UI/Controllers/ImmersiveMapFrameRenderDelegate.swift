// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import QuartzCore

/// Display-link delegate that prepares and renders one frame.
///
/// `currentTime` is the update's target presentation time: the instant this
/// frame is predicted to appear. It is used twice, and the pairing is the
/// point: time-based camera animations sample at it, and the drawable is
/// scheduled to present at it. The marker snapshot the frame publishes is
/// applied to the SwiftUI marker views on this same main-thread turn, so the
/// map pixels and the marker views are bound to one instant instead of
/// arriving through two independently timed paths.
@MainActor
final class ImmersiveMapFrameRenderDelegate: ImmersiveMapRenderDriverFrameDelegate {
    private let layer: CAMetalLayer
    private let renderRuntime: ImmersiveMapRenderRuntime
    private let viewportRuntime: ImmersiveMapViewportRuntime
    private let cameraAnimationRuntime: ImmersiveMapCameraAnimationRuntime

    init(layer: CAMetalLayer,
         renderRuntime: ImmersiveMapRenderRuntime,
         viewportRuntime: ImmersiveMapViewportRuntime,
         cameraAnimationRuntime: ImmersiveMapCameraAnimationRuntime) {
        self.layer = layer
        self.renderRuntime = renderRuntime
        self.viewportRuntime = viewportRuntime
        self.cameraAnimationRuntime = cameraAnimationRuntime
    }

    func renderDriverDidTick(_ driver: ImmersiveMapRenderDriver,
                             currentTime: CFTimeInterval,
                             drawable: any CAMetalDrawable) {
        guard renderRuntime.beginFrame() else {
            return
        }

        prepareRenderLoopFrame(currentTime: currentTime)
        guard renderRuntime.continueFrameAfterPreparation() else {
            return
        }

        renderRuntime.renderFrame(layer: layer,
                                  drawable: drawable,
                                  presentAt: currentTime,
                                  viewportRuntime: viewportRuntime)
    }

    private func prepareRenderLoopFrame(currentTime: CFTimeInterval) {
        cameraAnimationRuntime.advanceAnimationsIfNeeded(currentTime: currentTime)
    }
}

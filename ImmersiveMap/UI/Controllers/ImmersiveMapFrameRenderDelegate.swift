// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import QuartzCore

/// Display-link delegate, который готовит и рендерит один frame.
/// Перед draw продвигает time-based camera animations и передает текущий layer в render runtime.
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
                             currentTime: CFTimeInterval) {
        guard renderRuntime.beginFrame() else {
            return
        }

        prepareRenderLoopFrame(currentTime: currentTime)
        guard renderRuntime.continueFrameAfterPreparation() else {
            return
        }

        renderRuntime.renderFrame(layer: layer,
                                  viewportRuntime: viewportRuntime)
    }

    private func prepareRenderLoopFrame(currentTime: CFTimeInterval) {
        cameraAnimationRuntime.advanceAnimationsIfNeeded(currentTime: currentTime)
    }
}

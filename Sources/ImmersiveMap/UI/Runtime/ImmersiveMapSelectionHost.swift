// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics

/// The map view's side of the selection (`SelectionHost`): the viewport's
/// scale and the render loop, each from the runtime that owns it.
@MainActor
final class ImmersiveMapSelectionHost: SelectionHost {
    private let viewportRuntime: ImmersiveMapViewportRuntime
    private let renderRuntime: ImmersiveMapRenderRuntime

    init(viewportRuntime: ImmersiveMapViewportRuntime,
         renderRuntime: ImmersiveMapRenderRuntime) {
        self.viewportRuntime = viewportRuntime
        self.renderRuntime = renderRuntime
    }

    var contentsScale: CGFloat {
        viewportRuntime.contentsScale
    }

    func requestFrame() {
        renderRuntime.requestFrame()
    }
}

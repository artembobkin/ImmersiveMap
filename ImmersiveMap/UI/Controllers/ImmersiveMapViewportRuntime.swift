// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import CoreGraphics
import QuartzCore

/// Владеет viewport metrics, которые нужны rendering и hit-testing.
/// Синхронизирует `CAMetalLayer` frame/drawable size и отдает scale/renderability.
final class ImmersiveMapViewportRuntime {
    private(set) var bounds: CGRect = .zero
    private(set) var contentsScale: CGFloat = 1
    private(set) var drawableSize: CGSize = .zero

    var isRenderable: Bool {
        bounds.width > 0 && bounds.height > 0
    }

    @discardableResult
    func layout(layer: CAMetalLayer,
                bounds: CGRect,
                contentsScale: CGFloat) -> Bool {
        self.bounds = bounds
        self.contentsScale = contentsScale
        layer.frame = bounds

        let nextDrawableSize = CGSize(width: bounds.width * contentsScale,
                                      height: bounds.height * contentsScale)
        guard layer.drawableSize != nextDrawableSize else {
            drawableSize = layer.drawableSize
            return false
        }

        layer.drawableSize = nextDrawableSize
        drawableSize = nextDrawableSize
        return true
    }
}

#endif

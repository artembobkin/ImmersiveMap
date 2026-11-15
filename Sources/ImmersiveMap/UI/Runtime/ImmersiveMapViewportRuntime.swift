// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import QuartzCore

/// Owns the viewport metrics needed by rendering and hit-testing.
/// Synchronizes the `CAMetalLayer` frame/drawable size and exposes scale/renderability.
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
        #if canImport(UIKit)
        layer.frame = bounds
        #else
        // On macOS the metal layer is the NSView's backing layer, AppKit drives its frame.
        #endif

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

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics

enum DebugOverlayPanelLayout {
    static func visibleBodyHeight(preferredBodyHeight: CGFloat,
                                  viewportHeight: CGFloat,
                                  panelMinY: CGFloat,
                                  chromeHeight: CGFloat,
                                  minimumBodyHeight: CGFloat) -> CGFloat {
        let availableHeight = viewportHeight - panelMinY - chromeHeight
        let maximumBodyHeight = max(minimumBodyHeight, availableHeight)
        return min(preferredBodyHeight, maximumBodyHeight)
    }

    static func rowDrawRect(bounds: CGRect,
                            dirtyRect _: CGRect,
                            rowTop: CGFloat,
                            rowHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX,
               y: rowTop,
               width: bounds.width,
               height: rowHeight)
    }
}

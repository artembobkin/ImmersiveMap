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

    /// Height of a list that always reserves `slotCount` rows, whatever it
    /// currently holds. A list whose height follows its contents moves
    /// everything laid out after it, and in the debug panel that meant tiles
    /// arriving mid-zoom shoved the controls under the pointer.
    static func fixedListHeight(slotCount: Int,
                                slotHeight: CGFloat,
                                spacing: CGFloat) -> CGFloat {
        guard slotCount > 0 else { return 0 }
        return CGFloat(slotCount) * slotHeight + CGFloat(slotCount - 1) * spacing
    }

    /// How many rows of the given heights fit in `availableHeight`, laid out
    /// top-down with `spacing` between them. Rows are not all the same height
    /// (an expanded tile adds shorter child rows), so the count is walked
    /// rather than divided.
    static func visibleRowCount(rowHeights: [CGFloat],
                                spacing: CGFloat,
                                availableHeight: CGFloat) -> Int {
        var used: CGFloat = 0
        var count = 0
        for height in rowHeights {
            let next = count == 0 ? height : used + spacing + height
            guard next <= availableHeight else { break }
            used = next
            count += 1
        }
        return count
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

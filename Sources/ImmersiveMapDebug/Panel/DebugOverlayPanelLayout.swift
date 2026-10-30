// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap
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

    /// Width available to a row inside the scrolled column.
    ///
    /// Measured from the scroll view's content width rather than the panel's:
    /// a legacy scroller takes its width out of the content while an overlay
    /// one floats above it, and which of the two AppKit uses is a system
    /// setting, not the panel's choice. `scrollerGutter` is kept clear on the
    /// right so a right-aligned control lands under neither.
    static func scrolledContentWidth(scrollWidth: CGFloat,
                                     leadingInset: CGFloat,
                                     scrollerGutter: CGFloat) -> CGFloat {
        max(1, scrollWidth - leadingInset - scrollerGutter)
    }

    /// Right edge of a row laid out at `leadingInset` with that width; the
    /// value a right-aligned control's frame ends at.
    static func rowTrailingEdge(scrollWidth: CGFloat,
                                leadingInset: CGFloat,
                                scrollerGutter: CGFloat) -> CGFloat {
        leadingInset + scrolledContentWidth(scrollWidth: scrollWidth,
                                            leadingInset: leadingInset,
                                            scrollerGutter: scrollerGutter)
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

    /// The columns of a card grid: as many cards of `minimumCardWidth` as
    /// fit in `width` with `spacing` between them, one at least. The cards
    /// then stretch to share the width.
    static func cardColumnCount(width: CGFloat, minimumCardWidth: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int(((width + spacing) / (minimumCardWidth + spacing)).rounded(.down)))
    }

    /// The frame of the card at `index` in a grid of `columns`, filled
    /// row by row from the top left.
    static func cardFrame(index: Int, columns: Int, width: CGFloat, cardHeight: CGFloat, spacing: CGFloat) -> CGRect {
        let columns = max(1, columns)
        let cardWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let column = index % columns
        let row = index / columns
        return CGRect(x: CGFloat(column) * (cardWidth + spacing),
                      y: CGFloat(row) * (cardHeight + spacing),
                      width: cardWidth,
                      height: cardHeight)
    }

    /// The height of a grid holding `cardCount` cards in `columns`.
    static func cardGridHeight(cardCount: Int, columns: Int, cardHeight: CGFloat, spacing: CGFloat) -> CGFloat {
        let columns = max(1, columns)
        return fixedListHeight(slotCount: (cardCount + columns - 1) / columns, slotHeight: cardHeight, spacing: spacing)
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

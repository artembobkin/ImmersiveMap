// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics

struct DebugOverlayAtlasGridLayout: Equatable {
    let columnCount: Int
    let height: CGFloat
    let pageFrames: [DebugOverlayAtlasPageFrame]
}

struct DebugOverlayAtlasPageFrame: Equatable {
    let labelRect: CGRect
    let pageRect: CGRect
}

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

    static func atlasGridLayout(pageCount: Int,
                                width: CGFloat,
                                pageLabelHeight: CGFloat,
                                pageSpacing: CGFloat,
                                minimumPageSide: CGFloat,
                                maximumPageSide: CGFloat) -> DebugOverlayAtlasGridLayout {
        guard pageCount > 0 else {
            return DebugOverlayAtlasGridLayout(columnCount: 0, height: 0, pageFrames: [])
        }

        let availableWidth = max(width, 1)
        let minSide = max(minimumPageSide, 1)
        let maxSide = max(maximumPageSide, minSide)
        let columnCapacity = max(1, Int((availableWidth + pageSpacing) / (minSide + pageSpacing)))
        let columnCount = min(pageCount, columnCapacity)
        let pageSide = min(maxSide, max(1, (availableWidth - CGFloat(columnCount - 1) * pageSpacing) / CGFloat(columnCount)))
        let rowHeight = pageLabelHeight + pageSide
        let rowCount = Int(ceil(CGFloat(pageCount) / CGFloat(columnCount)))
        let height = CGFloat(rowCount) * rowHeight + CGFloat(max(0, rowCount - 1)) * pageSpacing
        let pageFrames = (0..<pageCount).map { index in
            let row = index / columnCount
            let column = index % columnCount
            let x = CGFloat(column) * (pageSide + pageSpacing)
            let y = CGFloat(row) * (rowHeight + pageSpacing)
            let labelRect = CGRect(x: x,
                                   y: y,
                                   width: pageSide,
                                   height: pageLabelHeight)
            let pageRect = CGRect(x: x,
                                  y: y + pageLabelHeight,
                                  width: pageSide,
                                  height: pageSide)
            return DebugOverlayAtlasPageFrame(labelRect: labelRect,
                                              pageRect: pageRect)
        }

        return DebugOverlayAtlasGridLayout(columnCount: columnCount,
                                           height: height,
                                           pageFrames: pageFrames)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreVideo
import SwiftUI

/// Pure placement math of the export marker compositor.
///
/// Both the marker projection (`MarkerProjectedEntry.positionPx`) and
/// CoreGraphics contexts use drawable pixels with a bottom-left origin and
/// y up, so no flip is involved. `UnitPoint` anchors measure y from the top of
/// the view, hence the `(1 - anchor.y)` term.
enum VideoExportMarkerCompositorMath {
    /// Rect (in bottom-up pixel space) placing the marker image so its
    /// `anchor` point lands exactly on `anchorPointPx`.
    static func rectPx(anchorPointPx: SIMD2<Float>,
                       sizePx: CGSize,
                       anchor: UnitPoint) -> CGRect {
        CGRect(x: CGFloat(anchorPointPx.x) - sizePx.width * anchor.x,
               y: CGFloat(anchorPointPx.y) - sizePx.height * (1 - anchor.y),
               width: sizePx.width,
               height: sizePx.height)
    }
}

/// SwiftUI markers for the offline export: the live map hosts them as platform
/// views above the Metal layer, which offscreen rendering cannot capture.
/// Instead, each marker view is rasterized once at export start, the export
/// engine projects the coordinates every frame exactly like the live overlay,
/// and the images are composited onto the finished frame's pixel buffer with
/// the projected position, anchor, and globe-horizon fade alpha.
@MainActor
final class VideoExportMarkerOverlay {
    private struct Item {
        let internalID: UInt64
        let image: CGImage
        let sizePx: CGSize
    }

    /// Items in z-order (collection order, last on top).
    private let items: [Item]
    private let anchor: UnitPoint
    let projectionInput: MarkerProjectionInput

    /// Rasterizes the marker views. Returns `nil` when there is nothing to
    /// composite (no items, or none of them produced an image).
    init?(content: MarkerViewContent, scale: Double) {
        var items: [Item] = []
        var entries: [MarkerProjectionEntry] = []
        items.reserveCapacity(content.items.count)
        entries.reserveCapacity(content.items.count)

        var nextInternalID: UInt64 = 1
        for viewItem in content.items {
            let renderer = ImageRenderer(content: viewItem.content)
            renderer.scale = scale
            guard let image = renderer.cgImage else {
                continue
            }
            let internalID = nextInternalID
            nextInternalID &+= 1
            items.append(Item(internalID: internalID,
                              image: image,
                              sizePx: CGSize(width: image.width, height: image.height)))
            entries.append(MarkerProjectionEntry(id: internalID,
                                                 basis: GeoProjectionBasis(coordinate: viewItem.coordinate)))
        }

        guard items.isEmpty == false else {
            return nil
        }
        self.items = items
        self.anchor = content.anchor
        self.projectionInput = MarkerProjectionInput(entries: entries)
    }

    /// Draws the markers of `snapshot` onto the finished frame. Call after the
    /// GPU completed the frame and before the buffer is appended to the writer.
    func composite(into pixelBuffer: CVPixelBuffer, snapshot: MarkerProjectionSnapshot) {
        guard snapshot.entries.isEmpty == false else {
            return
        }
        var entriesByID: [UInt64: MarkerProjectedEntry] = [:]
        entriesByID.reserveCapacity(snapshot.entries.count)
        for entry in snapshot.entries {
            entriesByID[entry.id] = entry
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: baseAddress,
                                      width: CVPixelBufferGetWidth(pixelBuffer),
                                      height: CVPixelBufferGetHeight(pixelBuffer),
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return
        }

        for item in items {
            guard let entry = entriesByID[item.internalID] else {
                continue
            }
            context.setAlpha(CGFloat(entry.visibilityAlpha))
            context.draw(item.image,
                         in: VideoExportMarkerCompositorMath.rectPx(anchorPointPx: entry.positionPx,
                                                                    sizePx: item.sizePx,
                                                                    anchor: anchor))
        }
    }
}

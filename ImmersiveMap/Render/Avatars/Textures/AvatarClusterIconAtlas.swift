// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  AvatarClusterIconAtlas.swift
//  ImmersiveMap
//

import CoreGraphics
import Foundation
import Metal
#if canImport(UIKit)
import UIKit
#endif

final class AvatarClusterIconAtlas {
    private let atlas: AvatarTextureAtlas
    private let cellSize: Int
    private var renderedPreviewImagesByID: [UInt64: [CGImage]] = [:]

    var textureArray: MTLTexture {
        atlas.textureArray
    }

    init(device: MTLDevice,
         atlasSize: Int,
         cellSize: Int,
         pagesMax: Int) {
        self.atlas = AvatarTextureAtlas(device: device,
                                        atlasSize: atlasSize,
                                        cellSize: cellSize,
                                        pagesMax: pagesMax)
        self.cellSize = cellSize
    }

    func update(cluster: AvatarClusterRenderable) -> AvatarAtlasSlot? {
        let previewImages = cluster.previewMarkers.map(\.image)
        // cluster.id - content-hash по memberIDs, поэтому бейдж с количеством у
        // закэшированной иконки всегда актуален; перерисовка нужна только если
        // сменились сами картинки превью.
        if let existingSlot = atlas.slot(for: cluster.id),
           isRenderedIconCurrent(id: cluster.id, previewImages: previewImages) {
            return existingSlot
        }

        guard let image = Self.makeIcon(previewImages: previewImages,
                                        count: cluster.memberIDs.count,
                                        size: cellSize) else {
            return nil
        }
        let slot = atlas.updateImage(id: cluster.id, image: image)
        if slot != nil {
            renderedPreviewImagesByID[cluster.id] = previewImages
        }
        return slot
    }

    func freeSlot(for id: UInt64) {
        renderedPreviewImagesByID.removeValue(forKey: id)
        atlas.freeSlot(for: id)
    }

    private func isRenderedIconCurrent(id: UInt64, previewImages: [CGImage]) -> Bool {
        guard let renderedImages = renderedPreviewImagesByID[id],
              renderedImages.count == previewImages.count else {
            return false
        }
        return zip(renderedImages, previewImages).allSatisfy { $0 === $1 }
    }

    private static func makeIcon(previewImages: [CGImage],
                                 count: Int,
                                 size: Int) -> CGImage? {
        let bytesPerRow = size * 4
        var data = Data(count: bytesPerRow * size)
        let didDraw = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(data: baseAddress,
                                          width: size,
                                          height: size,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Little
                                            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
                                            .rawValue)
            else {
                return false
            }

            let bounds = CGRect(x: 0, y: 0, width: size, height: size)
            context.clear(bounds)
            context.interpolationQuality = .high
            drawPreviews(previewImages, in: bounds, context: context)
            drawCountBadge(count: count, in: bounds, context: context)
            return true
        }
        guard didDraw,
              let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }
        return CGImage(width: size,
                       height: size,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo.byteOrder32Little
                        .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    private static func drawPreviews(_ images: [CGImage],
                                     in bounds: CGRect,
                                     context: CGContext) {
        let previewCount = max(1, min(3, images.count))
        let diameter = bounds.width * (previewCount == 1 ? 0.78 : 0.58)
        let centers: [CGPoint]
        switch previewCount {
        case 1:
            centers = [CGPoint(x: bounds.midX, y: bounds.midY)]
        case 2:
            centers = [
                CGPoint(x: bounds.midX - bounds.width * 0.15, y: bounds.midY + bounds.height * 0.05),
                CGPoint(x: bounds.midX + bounds.width * 0.15, y: bounds.midY - bounds.height * 0.05)
            ]
        default:
            centers = [
                CGPoint(x: bounds.midX, y: bounds.midY + bounds.height * 0.16),
                CGPoint(x: bounds.midX - bounds.width * 0.18, y: bounds.midY - bounds.height * 0.12),
                CGPoint(x: bounds.midX + bounds.width * 0.18, y: bounds.midY - bounds.height * 0.12)
            ]
        }

        let strokeWidth = max(2.0, bounds.width * 0.035)
        for index in 0..<previewCount {
            let center = centers[index]
            let rect = CGRect(x: center.x - diameter * 0.5,
                              y: center.y - diameter * 0.5,
                              width: diameter,
                              height: diameter)
            context.saveGState()
            context.addEllipse(in: rect)
            context.clip()
            if index < images.count {
                context.draw(images[index], in: rect)
            } else {
                context.setFillColor(CGColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1.0))
                context.fill(rect)
            }
            context.restoreGState()

            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.setLineWidth(strokeWidth)
            context.strokeEllipse(in: rect.insetBy(dx: strokeWidth * 0.5,
                                                   dy: strokeWidth * 0.5))
        }
    }

    private static func drawCountBadge(count: Int,
                                       in bounds: CGRect,
                                       context: CGContext) {
        #if canImport(UIKit)
        let label = count > 99 ? "99+" : "\(max(2, count))"
        let badgeHeight = max(24.0, bounds.height * 0.30)
        let badgeWidth = max(badgeHeight, bounds.width * (label.count > 2 ? 0.44 : 0.34))
        let badgeRect = CGRect(x: bounds.maxX - badgeWidth - bounds.width * 0.04,
                               y: bounds.minY + bounds.height * 0.05,
                               width: badgeWidth,
                               height: badgeHeight)
        let scale = max(UIScreen.main.scale, 1.0)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: badgeRect.size, format: format)
        let badgeImage = renderer.image { _ in
            let localBounds = CGRect(origin: .zero, size: badgeRect.size)
            let path = UIBezierPath(roundedRect: localBounds,
                                    cornerRadius: badgeHeight * 0.5)
            UIColor(red: 0.05, green: 0.07, blue: 0.10, alpha: 0.92).setFill()
            path.fill()
            UIColor.white.setStroke()
            path.lineWidth = max(1.5, bounds.width * 0.018)
            path.stroke()

            let font = UIFont.systemFont(ofSize: badgeHeight * 0.50, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white
            ]
            let textSize = label.size(withAttributes: attributes)
            let textRect = CGRect(x: localBounds.midX - textSize.width * 0.5,
                                  y: localBounds.midY - textSize.height * 0.5,
                                  width: textSize.width,
                                  height: textSize.height)
            label.draw(in: textRect, withAttributes: attributes)
        }
        if let cgImage = badgeImage.cgImage {
            context.draw(cgImage, in: badgeRect)
        }
        #endif
    }
}

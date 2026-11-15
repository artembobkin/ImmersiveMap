// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import CoreGraphics
import os
import simd
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum PinTextureRasterizer {
    private static let logger = Logger(subsystem: "ImmersiveMap", category: "Pins")

    static func makeBGRAData(for image: CGImage,
                             width: Int,
                             height: Int,
                             flipVertically: Bool = true) -> Data? {
        if let warning = imageSizeWarning(sourceWidth: image.width,
                                          sourceHeight: image.height,
                                          targetWidth: width,
                                          targetHeight: height) {
            logger.warning("\(warning, privacy: .public)")
        }

        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        var data = Data(count: byteCount)
        let didDraw = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let alphaInfo = CGImageAlphaInfo.premultipliedFirst
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: alphaInfo.rawValue))
            guard let context = CGContext(data: baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo.rawValue)
            else {
                return false
            }
            if flipVertically {
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return didDraw ? data : nil
    }

    static func imageSizeWarning(sourceWidth: Int,
                                 sourceHeight: Int,
                                 targetWidth: Int,
                                 targetHeight: Int) -> String? {
        guard sourceWidth != targetWidth || sourceHeight != targetHeight else {
            return nil
        }

        return "Pin pin image size mismatch: source \(sourceWidth)x\(sourceHeight), expected \(targetWidth)x\(targetHeight); image will be resampled into the pin atlas."
    }
}

struct PinAtlasSlot {
    let pageIndex: Int
    let cellX: Int
    let cellY: Int
    let uvRect: SIMD4<Float>
}

/// Atlas of pin images. Slots are keyed by CGImage identity rather than
/// pin id: thousands of pins sharing images share one slot. On overflow
/// the least recently used slot not touched by the current frame is evicted -
/// the atlas works as a cache of the visible scene.
final class PinTextureAtlas {
    private struct SlotState {
        var slot: PinAtlasSlot
        var lastUsedFrame: UInt64
    }

    private let device: MTLDevice
    private let atlasSize: Int
    private let cellSize: Int
    private let pagesMax: Int

    private(set) var textureArray: MTLTexture
    private var freeSlots: [PinAtlasSlot] = []
    private var slotsByImage: [ObjectIdentifier: SlotState] = [:]
    private var currentFrame: UInt64 = 0

    init(device: MTLDevice, atlasSize: Int, cellSize: Int, pagesMax: Int) {
        self.device = device
        self.atlasSize = atlasSize
        self.cellSize = cellSize
        self.pagesMax = pagesMax
        precondition(atlasSize % cellSize == 0, "Atlas size must be divisible by pin cell size.")
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.width = atlasSize
        descriptor.height = atlasSize
        descriptor.arrayLength = pagesMax
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let textureArray = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create pin atlas texture array.")
        }
        self.textureArray = textureArray
        appendSlots()
    }

    var slotCapacity: Int {
        let cellsPerSide = atlasSize / cellSize
        return cellsPerSide * cellsPerSide * pagesMax
    }

    /// Frame-start mark: slot usage is tracked per frame, and slots used by
    /// the current frame are never evicted.
    func beginFrame(_ frameIndex: UInt64) {
        currentFrame = frameIndex
    }

    /// Slot of an already-uploaded image; marks it as used this frame.
    func slot(for image: CGImage) -> PinAtlasSlot? {
        let key = ObjectIdentifier(image)
        guard var state = slotsByImage[key] else {
            return nil
        }
        if state.lastUsedFrame != currentFrame {
            state.lastUsedFrame = currentFrame
            slotsByImage[key] = state
        }
        return state.slot
    }

    /// Uploads the image into a free slot (or evicts the LRU one) and returns
    /// it; nil means the atlas is fully occupied by this frame's images.
    func uploadImage(_ image: CGImage) -> PinAtlasSlot? {
        let key = ObjectIdentifier(image)
        if let existing = slotsByImage[key] {
            return existing.slot
        }
        guard let slot = takeSlot() else {
            return nil
        }
        let bytesPerRow = cellSize * 4
        let byteCount = bytesPerRow * cellSize
        guard let data = PinTextureRasterizer.makeBGRAData(for: image,
                                                              width: cellSize,
                                                              height: cellSize)
        else {
            freeSlots.append(slot)
            return nil
        }

        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            let region = MTLRegionMake2D(slot.cellX * cellSize, slot.cellY * cellSize, cellSize, cellSize)
            textureArray.replace(region: region,
                                 mipmapLevel: 0,
                                 slice: slot.pageIndex,
                                 withBytes: base,
                                 bytesPerRow: bytesPerRow,
                                 bytesPerImage: byteCount)
        }
        slotsByImage[key] = SlotState(slot: slot, lastUsedFrame: currentFrame)
        return slot
    }

    private func takeSlot() -> PinAtlasSlot? {
        if let free = freeSlots.popLast() {
            return free
        }
        var oldestKey: ObjectIdentifier?
        var oldestFrame = UInt64.max
        for (key, state) in slotsByImage
        where state.lastUsedFrame < currentFrame && state.lastUsedFrame < oldestFrame {
            oldestKey = key
            oldestFrame = state.lastUsedFrame
        }
        guard let oldestKey, let evicted = slotsByImage.removeValue(forKey: oldestKey) else {
            return nil
        }
        return evicted.slot
    }

    private func appendSlots() {
        let cellsPerSide = atlasSize / cellSize
        let invSize = 1.0 / Float(atlasSize)
        for page in 0..<pagesMax {
            for y in 0..<cellsPerSide {
                for x in 0..<cellsPerSide {
                    let minX = Float(x * cellSize) * invSize
                    let minY = Float(y * cellSize) * invSize
                    let maxX = Float((x + 1) * cellSize) * invSize
                    let maxY = Float((y + 1) * cellSize) * invSize
                    freeSlots.append(PinAtlasSlot(pageIndex: page,
                                                     cellX: x,
                                                     cellY: y,
                                                     uvRect: SIMD4<Float>(minX, minY, maxX, maxY)))
                }
            }
        }
    }
}






struct PinCountBadgeAtlasSlot {
    let uvRect: SIMD4<Float>
}

private enum PinCountBadgeAtlasKey: Hashable {
    case count(Int)
    case overflow
}

/// Atlas of round bubble counters for merged pins: a white circle with the
/// number of merged pins; values above 999 are drawn as "999+".
final class PinCountBadgeAtlas {
    static let maximumCount = 999

    private let cellSize: Int
    private let columns: Int
    private let rows: Int

    private(set) var texture: MTLTexture
    private var slotsByKey: [PinCountBadgeAtlasKey: PinCountBadgeAtlasSlot] = [:]

    init(device: MTLDevice,
         badgePixelSize: Int,
         columns: Int = 20) {
        self.cellSize = max(1, badgePixelSize)
        self.columns = max(1, columns)
        self.rows = Int(ceil(Double(Self.maximumCount + 1) / Double(self.columns)))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: self.cellSize * self.columns,
                                                                  height: self.cellSize * self.rows,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create pin count badge atlas texture.")
        }
        texture.label = "PinCountBadgeAtlas"
        self.texture = texture
    }

    func slot(for badge: PinCountBadge) -> PinCountBadgeAtlasSlot? {
        let key: PinCountBadgeAtlasKey = badge.count > Self.maximumCount
            ? .overflow
            : .count(max(1, badge.count))
        if let existing = slotsByKey[key] {
            return existing
        }

        guard let image = makeBadgeImage(for: key) else {
            return nil
        }

        let atlasIndex: Int
        switch key {
        case .count(let count):
            atlasIndex = count - 1
        case .overflow:
            atlasIndex = Self.maximumCount
        }
        let column = atlasIndex % columns
        let row = atlasIndex / columns
        let minX = column * cellSize
        let minY = row * cellSize
        let bytesPerRow = cellSize * 4
        guard let data = PinTextureRasterizer.makeBGRAData(for: image,
                                                              width: cellSize,
                                                              height: cellSize)
        else {
            return nil
        }

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(minX, minY, cellSize, cellSize),
                            mipmapLevel: 0,
                            withBytes: baseAddress,
                            bytesPerRow: bytesPerRow)
        }

        let invWidth = 1.0 / Float(texture.width)
        let invHeight = 1.0 / Float(texture.height)
        let slot = PinCountBadgeAtlasSlot(
            uvRect: SIMD4<Float>(Float(minX) * invWidth,
                                 Float(minY) * invHeight,
                                 Float(minX + cellSize) * invWidth,
                                 Float(minY + cellSize) * invHeight)
        )
        slotsByKey[key] = slot
        return slot
    }

    private func makeBadgeImage(for key: PinCountBadgeAtlasKey) -> CGImage? {
        let size = CGSize(width: cellSize, height: cellSize)
        return PlatformGraphicsImageRenderer.makeCGImage(size: size) { _ in
            let bounds = CGRect(origin: .zero, size: size)
            let inset = max(size.width * 0.05, 1.5)
            let circleRect = bounds.insetBy(dx: inset, dy: inset)
            let circlePath = PlatformBezierPath(ovalIn: circleRect)
            PlatformColor.white.setFill()
            circlePath.fill()
            PlatformColor(white: 0.0, alpha: 0.10).setStroke()
            circlePath.lineWidth = max(size.width * 0.03, 1.0)
            circlePath.stroke()

            let textValue: String
            switch key {
            case .count(let count):
                textValue = "\(count)"
            case .overflow:
                textValue = "\(Self.maximumCount)+"
            }

            // Three-digit values are squeezed so they don't spill out of the circle.
            let baseFontSize = size.height * 0.44
            let fontScale: CGFloat = textValue.count <= 2 ? 1.0 : (textValue.count == 3 ? 0.82 : 0.66)
            let font = PlatformFont.monospacedDigitSystemFont(ofSize: baseFontSize * fontScale,
                                                              weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: PlatformColor(white: 0.08, alpha: 1.0)
            ]
            let text = textValue as NSString
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(x: circleRect.midX - textSize.width * 0.5,
                                  y: circleRect.midY - textSize.height * 0.5,
                                  width: ceil(textSize.width),
                                  height: ceil(textSize.height))
            text.draw(in: textRect, withAttributes: attributes)
        }
    }
}





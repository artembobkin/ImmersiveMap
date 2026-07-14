// Copyright (c) 2025-2026 ImmersiveMap contributors.
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

enum AvatarTextureRasterizer {
    private static let logger = Logger(subsystem: "ImmersiveMap", category: "Avatars")

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

        return "Avatar marker image size mismatch: source \(sourceWidth)x\(sourceHeight), expected \(targetWidth)x\(targetHeight); image will be resampled into the avatar atlas."
    }
}

struct AvatarAtlasSlot {
    let pageIndex: Int
    let cellX: Int
    let cellY: Int
    let uvRect: SIMD4<Float>
}

/// Атлас аватарных картинок. Слоты ключуются идентичностью CGImage, а не id
/// маркера: тысячи маркеров с общими картинками делят один слот. При
/// переполнении вытесняется наименее недавно использованный слот, не
/// задействованный в текущем кадре, - атлас работает как кеш видимой сцены.
final class AvatarTextureAtlas {
    private struct SlotState {
        var slot: AvatarAtlasSlot
        var lastUsedFrame: UInt64
    }

    private let device: MTLDevice
    private let atlasSize: Int
    private let cellSize: Int
    private let pagesMax: Int

    private(set) var textureArray: MTLTexture
    private var freeSlots: [AvatarAtlasSlot] = []
    private var slotsByImage: [ObjectIdentifier: SlotState] = [:]
    private var currentFrame: UInt64 = 0

    init(device: MTLDevice, atlasSize: Int, cellSize: Int, pagesMax: Int) {
        self.device = device
        self.atlasSize = atlasSize
        self.cellSize = cellSize
        self.pagesMax = pagesMax
        precondition(atlasSize % cellSize == 0, "Atlas size must be divisible by avatar cell size.")
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.width = atlasSize
        descriptor.height = atlasSize
        descriptor.arrayLength = pagesMax
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let textureArray = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create avatar atlas texture array.")
        }
        self.textureArray = textureArray
        appendSlots()
    }

    var slotCapacity: Int {
        let cellsPerSide = atlasSize / cellSize
        return cellsPerSide * cellsPerSide * pagesMax
    }

    /// Отметка начала кадра: использование слотов трекается покадрово, слоты
    /// текущего кадра не вытесняются.
    func beginFrame(_ frameIndex: UInt64) {
        currentFrame = frameIndex
    }

    /// Слот уже загруженной картинки; помечает использование в текущем кадре.
    func slot(for image: CGImage) -> AvatarAtlasSlot? {
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

    /// Загружает картинку в свободный слот (или вытесняет LRU) и возвращает
    /// его; nil - атлас целиком занят картинками текущего кадра.
    func uploadImage(_ image: CGImage) -> AvatarAtlasSlot? {
        let key = ObjectIdentifier(image)
        if let existing = slotsByImage[key] {
            return existing.slot
        }
        guard let slot = takeSlot() else {
            return nil
        }
        let bytesPerRow = cellSize * 4
        let byteCount = bytesPerRow * cellSize
        guard let data = AvatarTextureRasterizer.makeBGRAData(for: image,
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

    private func takeSlot() -> AvatarAtlasSlot? {
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
                    freeSlots.append(AvatarAtlasSlot(pageIndex: page,
                                                     cellX: x,
                                                     cellY: y,
                                                     uvRect: SIMD4<Float>(minX, minY, maxX, maxY)))
                }
            }
        }
    }
}

struct AvatarBatteryBadgeAtlasSlot {
    let uvRect: SIMD4<Float>
}

private enum AvatarBatteryBadgeAtlasKey: Hashable {
    case level(Int)
    case unavailable
}

private enum AvatarBatteryIconAsset: String {
    case low = "BatteryBadgeLow"
    case medium = "BatteryBadgeMedium"
    case high = "BatteryBadgeHigh"
}

struct AvatarBatteryBadgeImageLayout {
    let shellRect: CGRect
    let shellCornerRadius: CGFloat
    let contentRect: CGRect
    let spacing: CGFloat
    let fontSize: CGFloat
    let targetIconHeight: CGFloat

    init(size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        let shellInsetX = max(size.width * 0.07, 3.0)
        let shellInsetY = max(size.height * 0.09, 1.8)
        let shellRect = bounds.insetBy(dx: shellInsetX, dy: shellInsetY)

        let contentInsetX = max(size.width * 0.03, 1.5)
        let contentInsetY = max(size.height * 0.07, 1.4)
        let contentRect = shellRect.insetBy(dx: contentInsetX, dy: contentInsetY)

        self.shellRect = shellRect
        self.shellCornerRadius = shellRect.height * 0.34
        self.contentRect = contentRect
        self.spacing = max(size.width * 0.05, 4.5)
        self.fontSize = size.height * 0.40
        self.targetIconHeight = min(contentRect.height, size.height * 0.44)
    }
}

final class AvatarBatteryBadgeAtlas {
    private let device: MTLDevice
    private let cellWidth: Int
    private let cellHeight: Int
    private let columns: Int
    private let rows: Int

    private(set) var texture: MTLTexture
    private var slotsByKey: [AvatarBatteryBadgeAtlasKey: AvatarBatteryBadgeAtlasSlot] = [:]

    init(device: MTLDevice, badgePixelSize: SIMD2<Int>, columns: Int = 11) {
        self.device = device
        self.cellWidth = max(1, badgePixelSize.x)
        self.cellHeight = max(1, badgePixelSize.y)
        self.columns = max(1, columns)
        self.rows = Int(ceil(Double(102) / Double(self.columns)))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: self.cellWidth * self.columns,
            height: self.cellHeight * self.rows,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create avatar battery badge atlas texture.")
        }
        texture.label = "AvatarBatteryBadgeAtlas"
        self.texture = texture
    }

    func slot(for badge: AvatarBatteryBadge) -> AvatarBatteryBadgeAtlasSlot? {
        let key: AvatarBatteryBadgeAtlasKey = badge.isPlaceholder ? .unavailable : .level(badge.levelPct)
        if let existing = slotsByKey[key] {
            return existing
        }

        guard let image = makeBadgeImage(for: key) else {
            return nil
        }

        let atlasIndex: Int
        switch key {
        case .level(let level):
            atlasIndex = max(0, min(100, level))
        case .unavailable:
            atlasIndex = 101
        }
        let column = atlasIndex % columns
        let row = atlasIndex / columns
        let minX = column * cellWidth
        let minY = row * cellHeight
        let bytesPerRow = cellWidth * 4
        guard let data = AvatarTextureRasterizer.makeBGRAData(for: image,
                                                              width: cellWidth,
                                                              height: cellHeight)
        else {
            return nil
        }

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(minX, minY, cellWidth, cellHeight),
                            mipmapLevel: 0,
                            withBytes: baseAddress,
                            bytesPerRow: bytesPerRow)
        }

        let invWidth = 1.0 / Float(texture.width)
        let invHeight = 1.0 / Float(texture.height)
        let slot = AvatarBatteryBadgeAtlasSlot(
            uvRect: SIMD4<Float>(Float(minX) * invWidth,
                                 Float(minY) * invHeight,
                                 Float(minX + cellWidth) * invWidth,
                                 Float(minY + cellHeight) * invHeight)
        )
        slotsByKey[key] = slot
        return slot
    }

    private func makeBadgeImage(for key: AvatarBatteryBadgeAtlasKey) -> CGImage? {
        let size = CGSize(width: cellWidth, height: cellHeight)
        let layout = AvatarBatteryBadgeImageLayout(size: size)
        return PlatformGraphicsImageRenderer.makeCGImage(size: size) { _ in
            let shellPath = PlatformBezierPath(roundedRect: layout.shellRect, cornerRadius: layout.shellCornerRadius)
            PlatformColor.white.setFill()
            shellPath.fill()
            PlatformColor(white: 0.0, alpha: 0.06).setStroke()
            shellPath.lineWidth = 1.0
            shellPath.stroke()

            let textValue: String
            let iconAssetValue: AvatarBatteryIconAsset
            switch key {
            case .level(let levelPct):
                iconAssetValue = iconAsset(for: levelPct)
                textValue = "\(levelPct)%"
            case .unavailable:
                iconAssetValue = .medium
                textValue = "--"
            }

            let font = PlatformFont.monospacedDigitSystemFont(ofSize: layout.fontSize, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: PlatformColor(white: 0.08, alpha: 1.0)
            ]
            let text = textValue as NSString
            let textSize = text.size(withAttributes: attributes)

            let iconImage = loadIcon(asset: iconAssetValue)
                ?? makeFallbackIcon(asset: iconAssetValue, size: CGSize(width: 60, height: 36))
            let sourceIconSize = iconImage?.size ?? CGSize(width: 60, height: 36)
            let iconAspect = max(sourceIconSize.width / max(sourceIconSize.height, 1.0), 1.0)
            let iconSize = CGSize(width: layout.targetIconHeight * iconAspect,
                                  height: layout.targetIconHeight)

            let groupWidth = iconSize.width + layout.spacing + textSize.width
            let groupOriginX = layout.contentRect.midX - groupWidth * 0.5
            let iconRect = CGRect(x: groupOriginX,
                                  y: layout.contentRect.midY - iconSize.height * 0.5,
                                  width: iconSize.width,
                                  height: iconSize.height)
            let textRect = CGRect(x: iconRect.maxX + layout.spacing,
                                  y: layout.contentRect.midY - textSize.height * 0.5,
                                  width: ceil(textSize.width),
                                  height: ceil(textSize.height))

            iconImage?.draw(in: iconRect)
            text.draw(in: textRect, withAttributes: attributes)
        }
    }

    private func iconAsset(for levelPct: Int) -> AvatarBatteryIconAsset {
        switch levelPct {
        case ...20:
            return .low
        case ...50:
            return .medium
        default:
            return .high
        }
    }

    private func loadIcon(asset: AvatarBatteryIconAsset) -> PlatformImage? {
        PlatformImage(named: asset.rawValue)
    }

    private func makeFallbackIcon(asset: AvatarBatteryIconAsset, size: CGSize) -> PlatformImage? {
        PlatformGraphicsImageRenderer.makePlatformImage(size: size) { _ in
            let strokeColor = PlatformColor(white: 0.08, alpha: 1.0)
            strokeColor.setStroke()
            strokeColor.setFill()

            let bodyRect = CGRect(x: size.width * 0.08,
                                  y: size.height * 0.16,
                                  width: size.width * 0.72,
                                  height: size.height * 0.68)
            let tipRect = CGRect(x: bodyRect.maxX + size.width * 0.04,
                                 y: size.height * 0.36,
                                 width: size.width * 0.10,
                                 height: size.height * 0.28)

            let bodyPath = PlatformBezierPath(roundedRect: bodyRect, cornerRadius: size.height * 0.16)
            bodyPath.lineWidth = max(1.4, size.width * 0.08)
            bodyPath.stroke()

            let tipPath = PlatformBezierPath(roundedRect: tipRect, cornerRadius: size.width * 0.04)
            tipPath.lineWidth = max(1.2, size.width * 0.06)
            tipPath.stroke()

            let bars: Int
            switch asset {
            case .low:
                bars = 1
            case .medium:
                bars = 2
            case .high:
                bars = 3
            }

            let inset = max(bodyPath.lineWidth + 1.5, size.width * 0.08)
            let barArea = bodyRect.insetBy(dx: inset, dy: inset)
            let gap = max(size.width * 0.06, 1.5)
            let barWidth = (barArea.width - gap * 2) / 3
            for index in 0..<bars {
                let barRect = CGRect(x: barArea.minX + CGFloat(index) * (barWidth + gap),
                                     y: barArea.minY,
                                     width: barWidth,
                                     height: barArea.height)
                let barPath = PlatformBezierPath(roundedRect: barRect, cornerRadius: min(barRect.width, barRect.height) * 0.18)
                barPath.fill()
            }
        }
    }
}

struct AvatarSpeedBadgeAtlasSlot {
    let uvRect: SIMD4<Float>
}

private enum AvatarSpeedBadgeAtlasKey: Hashable {
    case speed(Int)
    case unavailable
}

private struct AvatarSpeedBadgeImageLayout {
    let shellRect: CGRect
    let shellCornerRadius: CGFloat
    let contentRect: CGRect
    let valueFontSize: CGFloat
    let unitFontSize: CGFloat
    let interLabelSpacing: CGFloat

    init(size: CGSize, cornerRadius: CGFloat) {
        let bounds = CGRect(origin: .zero, size: size)
        let insetX = max(size.width * 0.06, 2.5)
        let insetY = max(size.height * 0.08, 2.0)
        self.shellRect = bounds.insetBy(dx: insetX, dy: insetY)
        self.shellCornerRadius = min(cornerRadius, shellRect.height * 0.5)
        self.contentRect = shellRect.insetBy(dx: max(size.width * 0.08, 3.0),
                                             dy: max(size.height * 0.10, 2.0))
        self.valueFontSize = min(contentRect.height * 0.56, size.height * 0.44)
        self.unitFontSize = min(contentRect.height * 0.28, size.height * 0.21)
        self.interLabelSpacing = max(size.height * 0.02, 1.0)
    }
}

final class AvatarSpeedBadgeAtlas {
    static let unitText = "km/h"

    private let cellWidth: Int
    private let cellHeight: Int
    private let columns: Int
    private let rows: Int
    private let cornerRadiusPx: CGFloat

    private(set) var texture: MTLTexture
    private var slotsBySpeed: [AvatarSpeedBadgeAtlasKey: AvatarSpeedBadgeAtlasSlot] = [:]

    init(device: MTLDevice,
         badgePixelSize: SIMD2<Int>,
         cornerRadiusPx: Float,
         columns: Int = 20) {
        self.cellWidth = max(1, badgePixelSize.x)
        self.cellHeight = max(1, badgePixelSize.y)
        self.columns = max(1, columns)
        self.rows = Int(ceil(Double(1_001) / Double(self.columns)))
        self.cornerRadiusPx = CGFloat(cornerRadiusPx)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: self.cellWidth * self.columns,
                                                                  height: self.cellHeight * self.rows,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create avatar speed badge atlas texture.")
        }
        texture.label = "AvatarSpeedBadgeAtlas"
        self.texture = texture
    }

    func slot(for badge: AvatarSpeedBadge) -> AvatarSpeedBadgeAtlasSlot? {
        let key: AvatarSpeedBadgeAtlasKey = badge.isPlaceholder ? .unavailable : .speed(max(0, min(999, badge.kilometersPerHour)))
        if let existing = slotsBySpeed[key] {
            return existing
        }

        guard let image = makeBadgeImage(for: key) else {
            return nil
        }

        let atlasIndex: Int
        switch key {
        case .speed(let speed):
            atlasIndex = speed
        case .unavailable:
            atlasIndex = 1_000
        }
        let column = atlasIndex % columns
        let row = atlasIndex / columns
        let minX = column * cellWidth
        let minY = row * cellHeight
        let bytesPerRow = cellWidth * 4
        guard let data = AvatarTextureRasterizer.makeBGRAData(for: image,
                                                              width: cellWidth,
                                                              height: cellHeight)
        else {
            return nil
        }

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(minX, minY, cellWidth, cellHeight),
                            mipmapLevel: 0,
                            withBytes: baseAddress,
                            bytesPerRow: bytesPerRow)
        }

        let invWidth = 1.0 / Float(texture.width)
        let invHeight = 1.0 / Float(texture.height)
        let slot = AvatarSpeedBadgeAtlasSlot(
            uvRect: SIMD4<Float>(Float(minX) * invWidth,
                                 Float(minY) * invHeight,
                                 Float(minX + cellWidth) * invWidth,
                                 Float(minY + cellHeight) * invHeight)
        )
        slotsBySpeed[key] = slot
        return slot
    }

    private func makeBadgeImage(for key: AvatarSpeedBadgeAtlasKey) -> CGImage? {
        let size = CGSize(width: cellWidth, height: cellHeight)
        let layout = AvatarSpeedBadgeImageLayout(size: size, cornerRadius: cornerRadiusPx)
        return PlatformGraphicsImageRenderer.makeCGImage(size: size) { _ in
            let shellPath = PlatformBezierPath(roundedRect: layout.shellRect,
                                               cornerRadius: layout.shellCornerRadius)
            PlatformColor.white.setFill()
            shellPath.fill()
            PlatformColor(white: 0.0, alpha: 0.08).setStroke()
            shellPath.lineWidth = 1.0
            shellPath.stroke()

            let textValue: String
            switch key {
            case .speed(let kilometersPerHour):
                textValue = "\(kilometersPerHour)"
            case .unavailable:
                textValue = "--"
            }
            let text = textValue as NSString
            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: PlatformFont.monospacedDigitSystemFont(ofSize: layout.valueFontSize, weight: .bold),
                .foregroundColor: PlatformColor(white: 0.08, alpha: 1.0)
            ]
            let unitText = Self.unitText as NSString
            let unitAttributes: [NSAttributedString.Key: Any] = [
                .font: PlatformFont.systemFont(ofSize: layout.unitFontSize, weight: .bold),
                .foregroundColor: PlatformColor(white: 0.08, alpha: 1.0)
            ]
            let valueSize = text.size(withAttributes: valueAttributes)
            let unitSize = unitText.size(withAttributes: unitAttributes)
            let stackHeight = ceil(valueSize.height) + layout.interLabelSpacing + ceil(unitSize.height)
            let stackOriginY = layout.contentRect.midY - stackHeight * 0.5
            let valueRect = CGRect(x: layout.contentRect.midX - ceil(valueSize.width) * 0.5,
                                   y: stackOriginY,
                                   width: ceil(valueSize.width),
                                   height: ceil(valueSize.height))
            let unitRect = CGRect(x: layout.contentRect.midX - ceil(unitSize.width) * 0.5,
                                  y: valueRect.maxY + layout.interLabelSpacing,
                                  width: ceil(unitSize.width),
                                  height: ceil(unitSize.height))
            text.draw(in: valueRect, withAttributes: valueAttributes)
            unitText.draw(in: unitRect, withAttributes: unitAttributes)
        }
    }
}

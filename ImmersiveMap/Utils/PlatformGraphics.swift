// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit

typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformBezierPath = UIBezierPath
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit

typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformBezierPath = NSBezierPath
typealias PlatformImage = NSImage

extension NSBezierPath {
    /// Совместимость с сигнатурой `UIBezierPath(roundedRect:cornerRadius:)`
    /// для общего кода растеризации.
    convenience init(roundedRect rect: CGRect, cornerRadius: CGFloat) {
        self.init(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    }
}
#endif

enum PlatformDisplayScale {
    /// Scale главного экрана; используется офлайн-растеризацией, у которой нет своего view/window.
    static var main: CGFloat {
        #if canImport(UIKit)
        return max(UIScreen.main.scale, 1.0)
        #elseif canImport(AppKit)
        return max(NSScreen.main?.backingScaleFactor ?? 2.0, 1.0)
        #endif
    }
}

/// Кроссплатформенная растеризация в CGImage с top-left системой координат.
/// На iOS повторяет `UIGraphicsImageRenderer`; на macOS настраивает текущий
/// `NSGraphicsContext`, чтобы работали `NSBezierPath`, `NSImage.draw` и text drawing.
enum PlatformGraphicsImageRenderer {
    static func makeCGImage(size: CGSize,
                            scale: CGFloat = 1.0,
                            draw: (CGContext) -> Void) -> CGImage? {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { draw($0.cgContext) }.cgImage
        #elseif canImport(AppKit)
        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else {
            return nil
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Little
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let context = CGContext(data: nil,
                                      width: pixelWidth,
                                      height: pixelHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo.rawValue) else {
            return nil
        }

        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
        #endif
    }

    static func makePlatformImage(size: CGSize,
                                  scale: CGFloat = 1.0,
                                  draw: (CGContext) -> Void) -> PlatformImage? {
        guard let cgImage = makeCGImage(size: size,
                                        scale: scale,
                                        draw: draw) else {
            return nil
        }

        #if canImport(UIKit)
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: size)
        #endif
    }
}

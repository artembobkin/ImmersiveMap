// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// CPU-side generation of simple images for avatar markers.
///
/// Used when a network image is not needed and a drawn placeholder is
/// enough - for example a square with a large digit.
public enum AvatarMarkerImageFactory {
    /// Dark gray background, matching the built-in avatar placeholder.
    public static let defaultBackgroundColor = CGColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1.0)
    /// White text on top of the background.
    public static let defaultTextColor = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)

    /// Draws a square image with the given number centered.
    ///
    /// - Parameters:
    ///   - value: the number to draw.
    ///   - sizePx: side of the square in pixels.
    ///   - backgroundColor: background fill color.
    ///   - textColor: color of the digits.
    /// - Returns: a `CGImage` to pass to `AvatarMarker`.
    public static func number(_ value: Int,
                              sizePx: Int = 256,
                              backgroundColor: CGColor = defaultBackgroundColor,
                              textColor: CGColor = defaultTextColor) -> CGImage {
        let side = CGFloat(max(1, sizePx))
        let text = "\(value)" as NSString

        let image = PlatformGraphicsImageRenderer.makeCGImage(size: CGSize(width: side, height: side)) { _ in
            platformColor(from: backgroundColor).setFill()
            PlatformBezierPath(rect: CGRect(x: 0, y: 0, width: side, height: side)).fill()

            let foreground = platformColor(from: textColor)
            let maxWidth = side * 0.78
            let maxHeight = side * 0.72

            // Pick a font size so the number fits both in width and height.
            let probeSize: CGFloat = 100.0
            let probeAttributes: [NSAttributedString.Key: Any] = [
                .font: PlatformFont.systemFont(ofSize: probeSize, weight: .bold)
            ]
            let probe = text.size(withAttributes: probeAttributes)
            let scale = min(maxWidth / max(probe.width, 1.0), maxHeight / max(probe.height, 1.0))
            let fontSize = probeSize * scale

            let attributes: [NSAttributedString.Key: Any] = [
                .font: PlatformFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: foreground
            ]
            let textSize = text.size(withAttributes: attributes)
            let origin = CGPoint(x: (side - textSize.width) * 0.5,
                                 y: (side - textSize.height) * 0.5)
            text.draw(at: origin, withAttributes: attributes)
        }

        guard let image else {
            fatalError("Failed to render avatar number image for value \(value).")
        }
        return image
    }

    private static func platformColor(from cgColor: CGColor) -> PlatformColor {
        #if canImport(UIKit)
        return PlatformColor(cgColor: cgColor)
        #elseif canImport(AppKit)
        return PlatformColor(cgColor: cgColor) ?? .black
        #endif
    }
}

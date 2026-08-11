// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics
import CoreText
import Foundation

/// The portraits the crowd is drawn with, generated on the CPU.
///
/// `AvatarMarker` also takes a URL and loads it, which is what the avatars
/// example does with random faces from a photo service. A post cannot: the
/// export renders frame by frame from whatever has already loaded, and an
/// image that arrives late does not appear in the frames that were written
/// before it. A render started on a flaky connection would produce a video of
/// numbered placeholders, and two renders would differ. Drawing the portraits
/// here makes the crowd a pure function of the person list: no network, and
/// every take is identical.
///
/// The shape is a gradient tile with the initials on it, which is what a
/// contact list falls back to and reads at any size. A photograph would not:
/// a face at 113 px is mush, and fifty of them at once are fifty grey ovals,
/// while a saturated gradient is still a distinct person at a tenth of that.
enum CrowdPortraits {
    /// Source resolution of one portrait, matching the atlas cell
    /// (`AvatarSettings.Size.px256`). Markers draw at roughly half of this in a
    /// 1080p frame and at full size in a 4K one, so the cell is never
    /// magnified.
    static let sizePx = 256

    /// Gradient pairs, top-left to bottom-right. Vivid enough to separate one
    /// person from the next in a flower of seven petals, dark enough for white
    /// initials to hold their edge.
    private static let gradients: [(CGColor, CGColor)] = [
        (rgb(0.98, 0.42, 0.36), rgb(0.85, 0.18, 0.42)),
        (rgb(0.36, 0.62, 0.98), rgb(0.16, 0.32, 0.82)),
        (rgb(0.28, 0.78, 0.62), rgb(0.10, 0.52, 0.48)),
        (rgb(0.98, 0.70, 0.28), rgb(0.90, 0.44, 0.16)),
        (rgb(0.64, 0.46, 0.96), rgb(0.40, 0.24, 0.78)),
        (rgb(0.96, 0.46, 0.72), rgb(0.72, 0.20, 0.56)),
        (rgb(0.34, 0.72, 0.88), rgb(0.14, 0.44, 0.68)),
        (rgb(0.72, 0.80, 0.32), rgb(0.44, 0.58, 0.16)),
        (rgb(0.94, 0.56, 0.42), rgb(0.76, 0.30, 0.26)),
        (rgb(0.46, 0.54, 0.90), rgb(0.26, 0.28, 0.66)),
        (rgb(0.30, 0.82, 0.78), rgb(0.12, 0.56, 0.62)),
        (rgb(0.86, 0.42, 0.94), rgb(0.56, 0.20, 0.74)),
    ]

    /// Draws the portrait of `name`, picking the gradient from `paletteIndex`.
    static func portrait(name: String, paletteIndex: Int) -> CGImage {
        let side = sizePx
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: side,
                                      height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            fatalError("Failed to create the portrait context for \(name).")
        }

        let pair = gradients[((paletteIndex % gradients.count) + gradients.count) % gradients.count]
        drawGradient(from: pair.0, to: pair.1, in: context, side: side)
        drawInitials(of: name, in: context, side: side)

        guard let image = context.makeImage() else {
            fatalError("Failed to render the portrait for \(name).")
        }
        return image
    }

    private static func drawGradient(from start: CGColor,
                                     to end: CGColor,
                                     in context: CGContext,
                                     side: Int) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: colorSpace,
                                        colors: [start, end] as CFArray,
                                        locations: [0, 1]) else {
            context.setFillColor(start)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            return
        }
        let length = CGFloat(side)
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: length),
                                   end: CGPoint(x: length, y: 0),
                                   options: [])
    }

    /// Up to two initials, centered on their own glyph bounds rather than on
    /// the font's line box: "AB" and "JQ" have different ascenders and descenders,
    /// and a line-box centering puts them at visibly different heights on
    /// neighboring markers.
    private static func drawInitials(of name: String, in context: CGContext, side: Int) {
        let initials = self.initials(of: name)
        guard initials.isEmpty == false else {
            return
        }

        let font = NSFont.systemFont(ofSize: CGFloat(side) * 0.42, weight: .bold)
        let attributed = NSAttributedString(string: initials,
                                            attributes: [
                                                .font: font,
                                                .foregroundColor: NSColor.white,
                                                .kern: CGFloat(side) * 0.005,
                                            ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        context.saveGState()
        context.setShouldAntialias(true)
        context.textPosition = CGPoint(x: (CGFloat(side) - bounds.width) * 0.5 - bounds.minX,
                                       y: (CGFloat(side) - bounds.height) * 0.5 - bounds.minY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func initials(of name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: 1.0)
    }
}

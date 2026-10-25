// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO

/// A terrain tile decoded: its heights in metres, row by row from the
/// north edge, `size` a side.
struct GroundReliefHeights: Equatable {
    let size: Int
    let metres: [Float]
}

/// Decodes a terrain tile, a square image whose pixel holds its height in
/// metres in one of the RGB encodings
/// (`TileSettings.GroundReliefEncoding`). Any format ImageIO reads (PNG,
/// WebP).
enum GroundReliefDecoder {
    typealias Encoding = ImmersiveMapSettings.TileSettings.GroundReliefEncoding

    enum Failure: Error, Equatable {
        case unreadableImage
        case notSquare(width: Int, height: Int)
    }

    static func decode(_ data: Data, encoding: Encoding = .terrarium) throws -> GroundReliefHeights {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.unreadableImage
        }
        guard image.width == image.height, image.width > 0 else {
            throw Failure.notSquare(width: image.width, height: image.height)
        }
        let size = image.width
        // Drawn in the image's own colour space, so no colour conversion
        // touches the bytes: they are numbers, not colours.
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress,
                                          width: size,
                                          height: size,
                                          bitsPerComponent: 8,
                                          bytesPerRow: size * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else {
            throw Failure.unreadableImage
        }
        var metres = [Float](repeating: 0, count: size * size)
        for index in 0 ..< size * size {
            metres[index] = height(red: pixels[index * 4], green: pixels[index * 4 + 1], blue: pixels[index * 4 + 2],
                                   encoding: encoding)
        }
        return GroundReliefHeights(size: size, metres: metres)
    }

    /// The height of one pixel, in metres.
    static func height(red: UInt8, green: UInt8, blue: UInt8, encoding: Encoding = .terrarium) -> Float {
        switch encoding {
        case .terrarium:
            return Float(red) * 256 + Float(green) + Float(blue) / 256 - 32768
        case .mapbox:
            return (Float(red) * 65536 + Float(green) * 256 + Float(blue)) * 0.1 - 10000
        }
    }
}

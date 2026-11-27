// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO

public enum PinImageLoaderError: Error, Equatable {
    case invalidResponse
    case unacceptableStatusCode(Int)
    case cannotDecodeImage
}

public enum PinImageLoader {
    public static let defaultPlaceholderCGImage: CGImage = makeDefaultPlaceholderCGImage()

    public static func loadCGImage(from url: URL) async throws -> CGImage {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PinImageLoaderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw PinImageLoaderError.unacceptableStatusCode(httpResponse.statusCode)
        }

        return try decodeCGImage(data: data)
    }

    public static func decodeCGImage(data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PinImageLoaderError.cannotDecodeImage
        }
        return image
    }

    private static func makeDefaultPlaceholderCGImage() -> CGImage {
        let size = 64
        let bytesPerRow = size * 4
        var data = Data(repeating: 0, count: bytesPerRow * size)
        let image = data.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(data: baseAddress,
                                          width: size,
                                          height: size,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            // Draw in a top-down coordinate system, like the main pipeline
            // (makeBGRAData flipVertically), otherwise the placeholder ends up flipped in the texture.
            context.translateBy(x: 0, y: CGFloat(size))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(CGColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1.0))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.setFillColor(CGColor(red: 0.42, green: 0.46, blue: 0.52, alpha: 1.0))
            context.fillEllipse(in: CGRect(x: 22, y: 14, width: 20, height: 20))
            context.fillEllipse(in: CGRect(x: 14, y: 38, width: 36, height: 22))
            return context.makeImage()
        }

        guard let image else {
            fatalError("Failed to create default pin pin placeholder image.")
        }
        return image
    }
}

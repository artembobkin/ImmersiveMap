// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO

public enum AvatarMarkerImageLoaderError: Error, Equatable {
    case invalidResponse
    case unacceptableStatusCode(Int)
    case cannotDecodeImage
}

public enum AvatarMarkerImageLoader {
    public static let defaultPlaceholderCGImage: CGImage = makeDefaultPlaceholderCGImage()

    public static func loadCGImage(from url: URL) async throws -> CGImage {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AvatarMarkerImageLoaderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AvatarMarkerImageLoaderError.unacceptableStatusCode(httpResponse.statusCode)
        }

        return try decodeCGImage(data: data)
    }

    public static func decodeCGImage(data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AvatarMarkerImageLoaderError.cannotDecodeImage
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
            // Рисуем в системе координат «сверху вниз», как в основном пайплайне
            // (makeBGRAData flipVertically), иначе заглушка попадает в текстуру перевёрнутой.
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
            fatalError("Failed to create default avatar marker placeholder image.")
        }
        return image
    }
}

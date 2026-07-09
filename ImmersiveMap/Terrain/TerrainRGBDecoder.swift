// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO

enum TerrainRGBDecoder {
    static func heightMeters(r: UInt8,
                             g: UInt8,
                             b: UInt8,
                             encoding: ImmersiveMapTerrainSource.Encoding) -> Float {
        switch encoding {
        case .mapboxTerrainRGB:
            let value = Int(r) * 256 * 256 + Int(g) * 256 + Int(b)
            return -10000.0 + Float(value) * 0.1
        case .terrarium:
            return Float(Int(r) * 256 + Int(g)) + Float(b) / 256.0 - 32768.0
        }
    }

    static func decode(data: Data,
                       encoding: ImmersiveMapTerrainSource.Encoding) -> TerrainHeightGrid? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        return decode(image: image, encoding: encoding)
    }

    static func decode(image: CGImage,
                       encoding: ImmersiveMapTerrainSource.Encoding) -> TerrainHeightGrid? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(data: &bytes,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var heights: [Float] = []
        heights.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                heights.append(heightMeters(r: bytes[offset],
                                            g: bytes[offset + 1],
                                            b: bytes[offset + 2],
                                            encoding: encoding))
            }
        }
        return TerrainHeightGrid(width: width, height: height, heightsMeters: heights)
    }
}

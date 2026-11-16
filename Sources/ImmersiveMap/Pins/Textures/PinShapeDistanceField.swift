// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Metal

/// Turns a pin shape into the distance field the pin shader cuts its frame
/// from: for every texel, how far it is from the shape's edge, negative
/// inside. Baked on the CPU once per map, so a map's author gives a path and
/// never a prepared texture.
enum PinShapeDistanceField {
    /// The side of the baked texture, in texels.
    static let textureSize = 256
    /// The shape is filled at this many samples per texel side before the
    /// distances are taken, which places its edge to a quarter of a texel.
    static let supersampling = 2
    /// The part of the texture left empty on every side of the shape, so that
    /// the soft edge of a shape that touches its square is not cut.
    static let margin: CGFloat = 0.02
    /// The distance, in texels, the texture's range of values spans to each
    /// side of the edge. Wider than any outline or inset a pin can have.
    static let distanceRangeTexels: Float = 128.0

    /// Whether each sample of a `side` by `side` grid lies inside the shape.
    /// Row 0 is the top of the unit square.
    static func coverage(paths: [CGPath], side: Int) -> [Bool] {
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress,
                                          width: side,
                                          height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return
            }
            // The unit square, y down, laid inside the margin.
            context.translateBy(x: 0.0, y: CGFloat(side))
            context.scaleBy(x: CGFloat(side), y: -CGFloat(side))
            context.translateBy(x: margin, y: margin)
            context.scaleBy(x: 1.0 - 2.0 * margin, y: 1.0 - 2.0 * margin)
            context.clip(to: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
            context.setFillColor(gray: 1.0, alpha: 1.0)
            for path in paths {
                context.addPath(path)
                context.fillPath()
            }
        }
        return pixels.map { $0 >= 128 }
    }

    /// Whether each sample of a `side` by `side` grid lies inside the shape a
    /// mask pictures: where the mask is light and opaque. Row 0 is the top.
    static func coverage(mask: CGImage, side: Int) -> [Bool] {
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress,
                                          width: side,
                                          height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return
            }
            // Over black, a transparent part of the mask and a black one read
            // the same. The context is not flipped: an image drawn into one
            // comes out upright, its top in the first row.
            context.setFillColor(gray: 0.0, alpha: 1.0)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.interpolationQuality = .high
            let inset = margin * CGFloat(side)
            context.draw(mask, in: CGRect(x: inset,
                                          y: inset,
                                          width: CGFloat(side) - 2.0 * inset,
                                          height: CGFloat(side) - 2.0 * inset))
        }
        return pixels.map { $0 >= 128 }
    }

    /// The signed distance of every sample to the shape's edge, in samples,
    /// negative inside.
    static func signedDistances(inside: [Bool], side: Int) -> [Float] {
        let toInside = squaredDistances(toSamplesWhere: inside, side: side)
        let toOutside = squaredDistances(toSamplesWhere: inside.map { !$0 }, side: side)
        var distances = [Float](repeating: 0.0, count: side * side)
        for index in 0..<distances.count {
            // The edge runs between two samples, half a sample from each.
            if inside[index] {
                distances[index] = -(toOutside[index].squareRoot() - 0.5)
            } else {
                distances[index] = toInside[index].squareRoot() - 0.5
            }
        }
        return distances
    }

    /// The field as the texture stores it: `textureSize` squared 16-bit
    /// values, 0.5 on the edge, larger inside.
    static func encodedField(paths: [CGPath]) -> [UInt16] {
        encodedField(inside: coverage(paths: paths, side: fineSide))
    }

    static func encodedField(mask: CGImage) -> [UInt16] {
        encodedField(inside: coverage(mask: mask, side: fineSide))
    }

    /// The side of the grid the shape is filled on.
    static var fineSide: Int {
        textureSize * supersampling
    }

    /// `inside` is a grid of `fineSide` squared samples.
    static func encodedField(inside: [Bool]) -> [UInt16] {
        let fineSide = fineSide
        let fine = signedDistances(inside: inside, side: fineSide)
        var encoded = [UInt16](repeating: 0, count: textureSize * textureSize)
        let samplesPerTexel = Float(supersampling * supersampling)
        for y in 0..<textureSize {
            for x in 0..<textureSize {
                var sum: Float = 0.0
                for dy in 0..<supersampling {
                    for dx in 0..<supersampling {
                        sum += fine[(y * supersampling + dy) * fineSide + x * supersampling + dx]
                    }
                }
                let distanceTexels = sum / samplesPerTexel / Float(supersampling)
                encoded[y * textureSize + x] = encode(distanceTexels: distanceTexels)
            }
        }
        return encoded
    }

    static func encode(distanceTexels: Float) -> UInt16 {
        let unit = 0.5 - distanceTexels / (2.0 * distanceRangeTexels)
        return UInt16((min(max(unit, 0.0), 1.0) * 65535.0).rounded())
    }

    /// The texture of a shape's distance field. A shape without a frame has
    /// no field, and gets a single texel for the shader's texture slot. The
    /// built-in bubble has its own texture in the resources, and none here.
    static func makeTexture(device: MTLDevice, shape: PinShape) -> MTLTexture? {
        let side: Int
        let values: [UInt16]
        switch shape.outline {
        case .bubble:
            return nil
        case .paths(let paths):
            side = textureSize
            values = encodedField(paths: paths)
        case .mask(let mask):
            side = textureSize
            values = encodedField(mask: mask)
        case .picture:
            side = 1
            values = [encode(distanceTexels: -distanceRangeTexels)]
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm,
                                                                  width: side,
                                                                  height: side,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        texture.label = "Pin shape distance field"
        values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, side, side),
                            mipmapLevel: 0,
                            withBytes: baseAddress,
                            bytesPerRow: side * MemoryLayout<UInt16>.stride)
        }
        return texture
    }

    // MARK: - Distance transform

    private static let far: Float = 1.0e12

    /// For every sample, the squared distance to the nearest sample that is
    /// set: the exact Euclidean transform, one pass along the rows and one
    /// along the columns (Felzenszwalb and Huttenlocher).
    private static func squaredDistances(toSamplesWhere isSet: [Bool], side: Int) -> [Float] {
        var grid = isSet.map { $0 ? Float(0.0) : far }
        var line = [Float](repeating: 0.0, count: side)
        var result = [Float](repeating: 0.0, count: side)
        var parabolas = [Int](repeating: 0, count: side)
        var bounds = [Float](repeating: 0.0, count: side + 1)

        for y in 0..<side {
            for x in 0..<side { line[x] = grid[y * side + x] }
            transformLine(line, into: &result, parabolas: &parabolas, bounds: &bounds)
            for x in 0..<side { grid[y * side + x] = result[x] }
        }
        for x in 0..<side {
            for y in 0..<side { line[y] = grid[y * side + x] }
            transformLine(line, into: &result, parabolas: &parabolas, bounds: &bounds)
            for y in 0..<side { grid[y * side + x] = result[y] }
        }
        return grid
    }

    /// The lower envelope of the parabolas that stand on a line's samples.
    private static func transformLine(_ line: [Float],
                                      into result: inout [Float],
                                      parabolas: inout [Int],
                                      bounds: inout [Float]) {
        let count = line.count
        var last = 0
        parabolas[0] = 0
        bounds[0] = -Float.greatestFiniteMagnitude
        bounds[1] = Float.greatestFiniteMagnitude
        for sample in 1..<count {
            var crossing: Float
            while true {
                let other = parabolas[last]
                crossing = ((line[sample] + Float(sample * sample))
                            - (line[other] + Float(other * other)))
                    / Float(2 * (sample - other))
                if crossing <= bounds[last], last > 0 {
                    last -= 1
                } else {
                    break
                }
            }
            last += 1
            parabolas[last] = sample
            bounds[last] = crossing
            bounds[last + 1] = Float.greatestFiniteMagnitude
        }
        var current = 0
        for sample in 0..<count {
            while bounds[current + 1] < Float(sample) {
                current += 1
            }
            let offset = Float(sample - parabolas[current])
            result[sample] = offset * offset + line[parabolas[current]]
        }
    }
}

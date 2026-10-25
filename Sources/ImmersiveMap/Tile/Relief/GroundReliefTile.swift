// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Accelerate
import Metal
import simd

/// One terrain tile's heights: as half floats in a texture for the GPU,
/// and the same halves on the CPU for what is placed by it there (the
/// camera, the labels, the buildings' lifts). Half floats filter on every
/// GPU, so the vertex stage takes one bilinear sample, and they step by
/// half a metre at 1000 m and 2 m at 4000 m, well under the ground's grid.
///
/// The edges are welded to the neighbours' of the same zoom once they are
/// in (`GroundReliefEdgeWeld`): the texels along an edge take the mean of
/// the tile's and its neighbour's, the height that lies on the edge
/// itself, so two tiles meet there with one height and the ground drawn
/// over them closes. The texels change in place, written on the main
/// thread only (`GroundReliefStore.applyPendingWelds`), as everything that
/// reads them reads there.
///
/// Shared across threads (`@unchecked Sendable`): made on a load's task,
/// then its texels written on the main thread alone and its occlusion
/// under the store's lock alone (`setOcclusion`), each read where it is
/// written.
final class GroundReliefTile: @unchecked Sendable {
    /// `r16Float`, row 0 at the north edge.
    let texture: MTLTexture
    let size: Int
    /// The texture's texels, row by row, with the edges as welded.
    private(set) var halves: [UInt16]
    /// The edges as decoded, which every weld averages from, so the weld
    /// is the same whatever order the neighbours came in.
    let originalEdges: Edges
    /// The lowest and the highest height in the tile, in metres, the
    /// welded edges included.
    private(set) var heightRange: ClosedRange<Float>
    /// Grows with every weld written into the texels: what was placed by
    /// them on the CPU (the buildings' lifts) is placed again.
    private(set) var revision: UInt64 = 0
    /// The tile's occlusion of the sky as an `r8Unorm` texture
    /// (`GroundReliefOcclusion`), and the key it was computed with, nil
    /// until computed. Set under the store's lock, read there.
    private(set) var occlusion: MTLTexture?
    private(set) var occlusionKey: GroundReliefOcclusion.Key?

    func setOcclusion(_ texture: MTLTexture?, key: GroundReliefOcclusion.Key?) {
        occlusion = texture
        occlusionKey = key
    }

    /// A tile's four edges, `size` texels each: the north and the south
    /// rows west to east, the west and the east columns north to south.
    struct Edges {
        let north: [UInt16]
        let south: [UInt16]
        let west: [UInt16]
        let east: [UInt16]
    }

    init(texture: MTLTexture, size: Int, halves: [UInt16], heightRange: ClosedRange<Float>) {
        self.texture = texture
        self.size = size
        self.halves = halves
        self.heightRange = heightRange
        self.originalEdges = Edges(north: Array(halves[0 ..< size]),
                                   south: Array(halves[(size - 1) * size ..< size * size]),
                                   west: (0 ..< size).map { halves[$0 * size] },
                                   east: (0 ..< size).map { halves[$0 * size + size - 1] })
    }

    /// A decoded tile's heights as half floats, in a texture for the GPU
    /// and on the CPU. Off the main thread, on the load's own task.
    static func make(heights: GroundReliefHeights, device: MTLDevice) throws -> GroundReliefTile {
        let size = heights.size
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw URLError(.cannotCreateFile)
        }
        var halves = [UInt16](repeating: 0, count: size * size)
        var metres = heights.metres
        metres.withUnsafeMutableBytes { source in
            halves.withUnsafeMutableBytes { destination in
                var sourceBuffer = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(size),
                                                 width: vImagePixelCount(size), rowBytes: size * 4)
                var destinationBuffer = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(size),
                                                      width: vImagePixelCount(size), rowBytes: size * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&sourceBuffer, &destinationBuffer, vImage_Flags(kvImageNoFlags))
            }
        }
        halves.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, size, size),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: size * MemoryLayout<UInt16>.stride)
        }
        var lowest: Float = 0
        var highest: Float = 0
        vDSP_minv(heights.metres, 1, &lowest, vDSP_Length(heights.metres.count))
        vDSP_maxv(heights.metres, 1, &highest, vDSP_Length(heights.metres.count))
        return GroundReliefTile(texture: texture,
                                size: size,
                                halves: halves,
                                heightRange: min(lowest, highest) ... max(lowest, highest))
    }

    /// Half floats' values.
    static func floats(halfBits bits: [UInt16]) -> [Float] {
        bits.map(float(halfBits:))
    }

    var costInBytes: Int {
        texture.allocatedSize + (halves.count + size * 4) * MemoryLayout<UInt16>.stride + (occlusion?.allocatedSize ?? 0)
    }

    /// Writes texels of a welded edge on the CPU, a rectangle of `width` by
    /// `height` from the column `x` and the row `y`, row by row: the
    /// texture takes the same through the GPU
    /// (`GroundReliefStore.applyPendingWelds`). Main thread only.
    func writeTexels(_ values: [UInt16], x: Int, y: Int, width: Int, height: Int) {
        var lowest = heightRange.lowerBound
        var highest = heightRange.upperBound
        for row in 0 ..< height {
            for column in 0 ..< width {
                let value = values[row * width + column]
                halves[(y + row) * size + x + column] = value
                let metres = Self.float(halfBits: value)
                lowest = min(lowest, metres)
                highest = max(highest, metres)
            }
        }
        heightRange = lowest ... highest
        revision &+= 1
    }

    /// The height in metres at a point of the texture, in 0...1, bilinear
    /// between the four texels around it, the texels at the edge
    /// repeating outward as the sampler clamps.
    func metres(atTextureUV uv: SIMD2<Float>) -> Float {
        let last = Float(size - 1)
        let texel = simd_clamp(uv * Float(size) - 0.5, SIMD2<Float>(repeating: 0), SIMD2<Float>(repeating: last))
        let lower = SIMD2<Int>(Int(texel.x), Int(texel.y))
        let upper = SIMD2<Int>(min(lower.x + 1, size - 1), min(lower.y + 1, size - 1))
        let blend = texel - SIMD2<Float>(Float(lower.x), Float(lower.y))
        return halves.withUnsafeBufferPointer { halves in
            let north = simd_mix(Self.float(halfBits: halves[lower.y * size + lower.x]),
                                 Self.float(halfBits: halves[lower.y * size + upper.x]),
                                 blend.x)
            let south = simd_mix(Self.float(halfBits: halves[upper.y * size + lower.x]),
                                 Self.float(halfBits: halves[upper.y * size + upper.x]),
                                 blend.x)
            return simd_mix(north, south, blend.y)
        }
    }

    /// A half float's value, by its bits: Float16 is not on every platform
    /// the package builds for.
    @inline(__always)
    static func float(halfBits bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x3FF)
        if exponent == 0 {
            // A subnormal, or zero: the mantissa over 2^24.
            return Float(sign == 0 ? 1 : -1) * Float(mantissa) * 5.960464477539063e-8
        }
        if exponent == 0x1F {
            return Float(bitPattern: sign | 0x7F80_0000 | mantissa << 13)
        }
        return Float(bitPattern: sign | UInt32(exponent + 112) << 23 | mantissa << 13)
    }
}

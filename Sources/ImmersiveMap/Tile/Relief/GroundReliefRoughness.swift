// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Accelerate
import Foundation
import Metal
import simd

/// How much of a mountain the ground of a terrain tile is, point by point:
/// a grid of cells over the tile, each the share, 0 to 1, that the rise
/// and fall of the terrain within `GroundReliefSettings.reliefWindowMetres`
/// of the cell makes of it, 0 under `flatReliefMetres` and 1 over
/// `mountainReliefMetres`, a smoothstep between. The share is a property
/// of the place, read off the terrain once when the tile lands, never of
/// the camera: the fades that take the relief away with the zoom are
/// blended by it (`GroundReliefFrame`), so a city goes flat early, a
/// mountain late and foothills between, and a pan at one zoom changes
/// nothing, since no point's share moves with the camera. Neighbouring
/// cells share most of their window, so the share runs smoothly over the
/// country, and the vertex stages sample it bilinearly, as the heights.
///
/// Computed from the tile's own heights, so the window is cut at the
/// tile's edge: the share near an edge reads less country than one in
/// the middle, which a tile coarse enough to hold the window many times
/// over makes small (`GroundReliefSettings.roughnessZoom`).
final class GroundReliefRoughness {
    /// `r16Float`, row 0 at the north edge, `cells` a side.
    let texture: MTLTexture
    let cells: Int
    /// The shares, row by row.
    let shares: [Float]

    init(texture: MTLTexture, cells: Int, shares: [Float]) {
        self.texture = texture
        self.cells = cells
        self.shares = shares
    }

    var costInBytes: Int {
        texture.allocatedSize + shares.count * MemoryLayout<Float>.stride
    }

    /// The share at a point of the texture, in 0...1, bilinear between the
    /// four cells around it, the cells at the edge repeating outward as
    /// the sampler clamps.
    func share(atTextureUV uv: SIMD2<Float>) -> Float {
        let last = Float(cells - 1)
        let cell = simd_clamp(uv * Float(cells) - 0.5, SIMD2<Float>(repeating: 0), SIMD2<Float>(repeating: last))
        let lower = SIMD2<Int>(Int(cell.x), Int(cell.y))
        let upper = SIMD2<Int>(min(lower.x + 1, cells - 1), min(lower.y + 1, cells - 1))
        let blend = cell - SIMD2<Float>(Float(lower.x), Float(lower.y))
        let north = simd_mix(shares[lower.y * cells + lower.x], shares[lower.y * cells + upper.x], blend.x)
        let south = simd_mix(shares[upper.y * cells + lower.x], shares[upper.y * cells + upper.x], blend.x)
        return simd_mix(north, south, blend.y)
    }

    /// The most cells a side: a cell is then about 1.7 km of a zoom 8
    /// tile at the Alps' latitude, well under the window.
    static let maximumCells = 64

    /// The roughness of a terrain tile from its heights. The heights are
    /// first taken to blocks, the lowest and highest of each, one block a
    /// cell, and each cell's rise is the highest less the lowest over the
    /// blocks within half the window of it, the window clamped to the
    /// tile.
    static func make(heights: GroundReliefHeights,
                     tile: Tile,
                     windowMetres: Float,
                     flatMetres: Float,
                     mountainMetres: Float,
                     device: MTLDevice) -> GroundReliefRoughness? {
        let size = heights.size
        guard size > 0 else { return nil }
        let cells = min(maximumCells, size)
        let block = size / cells
        var lowest = [Float](repeating: .greatestFiniteMagnitude, count: cells * cells)
        var highest = [Float](repeating: -.greatestFiniteMagnitude, count: cells * cells)
        heights.metres.withUnsafeBufferPointer { metres in
            for row in 0 ..< size {
                let cellRow = min(row / block, cells - 1)
                for column in 0 ..< size {
                    let cellColumn = min(column / block, cells - 1)
                    let value = metres[row * size + column]
                    let index = cellRow * cells + cellColumn
                    if value < lowest[index] { lowest[index] = value }
                    if value > highest[index] { highest[index] = value }
                }
            }
        }
        // The window in cells: the tile's span in metres at its latitude
        // over the cells.
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: (Double(tile.y) + 0.5) / Double(1 << tile.z))
        let spanMetres = ImmersiveMapProjection.earthCircumferenceMeters * max(cos(latitude), 1e-6) / Double(1 << tile.z)
        let cellMetres = spanMetres / Double(cells)
        let radius = max(0, Int((Double(windowMetres) * 0.5 / cellMetres).rounded(.up)))
        // The window's lowest and highest over the blocks, one axis at a
        // time: along each row first, then down each column of that, which
        // is the square window's, at the cost of the window's width twice
        // per cell rather than its area.
        let rowLowest = Self.windowed(lowest, cells: cells, radius: radius, alongRows: true, keep: min)
        let rowHighest = Self.windowed(highest, cells: cells, radius: radius, alongRows: true, keep: max)
        let windowLowest = Self.windowed(rowLowest, cells: cells, radius: radius, alongRows: false, keep: min)
        let windowHighest = Self.windowed(rowHighest, cells: cells, radius: radius, alongRows: false, keep: max)
        let span = max(mountainMetres - flatMetres, 1)
        var shares = [Float](repeating: 0, count: cells * cells)
        for index in shares.indices {
            let rise = windowHighest[index] - windowLowest[index]
            let t = min(max((rise - flatMetres) / span, 0), 1)
            shares[index] = t * t * (3 - 2 * t)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float,
                                                                  width: cells,
                                                                  height: cells,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "GroundReliefRoughness"
        var halves = [UInt16](repeating: 0, count: cells * cells)
        var floats = shares
        floats.withUnsafeMutableBytes { source in
            halves.withUnsafeMutableBytes { destination in
                var sourceBuffer = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(cells),
                                                 width: vImagePixelCount(cells), rowBytes: cells * 4)
                var destinationBuffer = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(cells),
                                                      width: vImagePixelCount(cells), rowBytes: cells * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&sourceBuffer, &destinationBuffer, vImage_Flags(kvImageNoFlags))
            }
        }
        halves.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, cells, cells),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: cells * MemoryLayout<UInt16>.stride)
        }
        return GroundReliefRoughness(texture: texture, cells: cells, shares: shares)
    }

    /// Each cell's `keep` (the lowest or the highest) over the cells
    /// within `radius` of it along one axis, the window clamped to the
    /// grid.
    private static func windowed(_ values: [Float],
                                 cells: Int,
                                 radius: Int,
                                 alongRows: Bool,
                                 keep: (Float, Float) -> Float) -> [Float] {
        var result = values
        for line in 0 ..< cells {
            for position in 0 ..< cells {
                var kept = values[alongRows ? line * cells + position : position * cells + line]
                for other in max(0, position - radius) ... min(cells - 1, position + radius) {
                    kept = keep(kept, values[alongRows ? line * cells + other : other * cells + line])
                }
                result[alongRows ? line * cells + position : position * cells + line] = kept
            }
        }
        return result
    }
}

/// The frame's part of the relief's strength (`GroundReliefStore.setFrame`):
/// what the zoom fades leave of the relief at the frame's camera zoom for
/// a place of a given mountain share, times the configured exaggeration
/// and the fade the relief comes in by. The flat fade's zooms and the
/// mountain fade's are blended by the share, and the relief faded between
/// the blended zooms: the share moves the zoom the relief goes at, early
/// over flat ground and late in the mountains, between them in between,
/// and the relief always goes whole. A fade of `ImmersiveMapZoomFade.none`
/// stands at an infinite zoom, so the relief stays wherever that fade has
/// any share. The vertex stages compute the same (GroundRelief.h).
struct GroundReliefFrame: Equatable {
    let cameraZoom: Float
    /// The configured exaggeration times the appear fade's alpha.
    let strengthScale: Float
    /// Each fade's zero-alpha zoom and full-alpha zoom.
    let flat: SIMD2<Float>
    let mountain: SIMD2<Float>

    /// Everything flat, nothing fading: the relief as configured.
    static let plain = GroundReliefFrame(cameraZoom: 0, strengthScale: 1, flat: Self.noFade, mountain: Self.noFade)

    /// A fade that never comes: a fade-out far past any zoom (the zooms
    /// run to 24), from ten thousand to twenty, so it reads as full at
    /// every zoom, and a blend of it with a real fade at any share short
    /// of one lies past every zoom too. Not farther out than that: a float
    /// blend of a huge zoom with a real one would lose the real one.
    static let noFade = SIMD2<Float>(2e4, 1e4)

    init(cameraZoom: Float, strengthScale: Float, flat: SIMD2<Float>, mountain: SIMD2<Float>) {
        self.cameraZoom = cameraZoom
        self.strengthScale = strengthScale
        self.flat = flat
        self.mountain = mountain
    }

    init(cameraZoom: Double,
         strengthScale: Float,
         flatZoomFade: ImmersiveMapZoomFade,
         mountainZoomFade: ImmersiveMapZoomFade) {
        self.init(cameraZoom: Float(cameraZoom),
                  strengthScale: strengthScale,
                  flat: Self.zooms(of: flatZoomFade),
                  mountain: Self.zooms(of: mountainZoomFade))
    }

    static func zooms(of fade: ImmersiveMapZoomFade) -> SIMD2<Float> {
        fade == .none ? noFade : SIMD2<Float>(Float(fade.zeroAlphaZoom), Float(fade.fullAlphaZoom))
    }

    /// The share of the relief the fades leave at the frame's zoom for a
    /// place of `mountainShare`.
    func fadeAlpha(mountainShare: Float) -> Float {
        let share = min(max(mountainShare, 0), 1)
        let zeroFull = simd_mix(flat, mountain, SIMD2<Float>(repeating: share))
        let progress = min(max((cameraZoom - zeroFull.x) / (zeroFull.y - zeroFull.x), 0), 1)
        return progress * progress * (3 - 2 * progress)
    }

    /// How much taller than the terrain a place of `mountainShare` is
    /// drawn this frame.
    func strength(mountainShare: Float) -> Float {
        strengthScale * fadeAlpha(mountainShare: mountainShare)
    }
}

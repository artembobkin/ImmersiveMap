// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The pipelines of the tile grid (TileGrid.metal): the patch of a tile,
/// which carries its border and its selected fill, and the glyphs of its
/// text, each in one variant per surface the ground is drawn on
/// (`Surface`), in the overlay pass's formats and its one sample, blended
/// over the frame. The shaders read their vertices from buffers by index, so
/// no vertex descriptor.
final class TileGridPipeline {
    /// Mirrors `kTileGridSurface` in TileGrid.metal.
    enum Surface: Int, CaseIterable {
        case flat = 0
        case sphere = 1
        case morph = 2
    }

    struct States {
        let patch: MTLRenderPipelineState
        let glyph: MTLRenderPipelineState
    }

    /// The quads along a side of the lattice every patch is cut from: the
    /// finest a tile is divided. `kTileGridLatticePoints` in TileGrid.metal
    /// is one more.
    static let latticeSide = 64
    /// How many quads along a side a patch may be drawn with, each a
    /// set of indices over the one lattice.
    static let subdivisions = [1, 4, 8, 16, 32, 64]

    private let statesBySurface: [Surface: States]
    private let latticeIndicesBySubdivision: [Int: (buffer: MTLBuffer, count: Int)]
    /// How the grid is tested where it draws: not at all. It draws in the
    /// overlay pass, over the finished world and the map's names, and
    /// neither reads nor writes that pass's depth.
    let depthState: MTLDepthStencilState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        func makeState(vertex: String, fragment: String, surface: Surface) -> MTLRenderPipelineState {
            let values = MTLFunctionConstantValues()
            var surfaceValue = Int32(surface.rawValue)
            values.setConstantValue(&surfaceValue, type: .int, index: 0)
            descriptor.vertexFunction = try! library.makeFunction(name: vertex, constantValues: values)
            descriptor.fragmentFunction = try! library.makeFunction(name: fragment, constantValues: values)
            return try! metalDevice.makeRenderPipelineState(descriptor: descriptor)
        }
        var states: [Surface: States] = [:]
        for surface in Surface.allCases {
            states[surface] = States(patch: makeState(vertex: "tileGridPatchVertex",
                                                      fragment: "tileGridPatchFragment",
                                                      surface: surface),
                                     glyph: makeState(vertex: "tileGridGlyphVertex",
                                                      fragment: "tileGridGlyphFragment",
                                                      surface: surface))
        }
        statesBySurface = states

        var lattices: [Int: (buffer: MTLBuffer, count: Int)] = [:]
        for subdivision in Self.subdivisions {
            let indices = Self.latticeIndices(subdivision: subdivision)
            let buffer = indices.withUnsafeBytes { bytes in
                metalDevice.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)!
            }
            buffer.label = "Tile grid lattice \(subdivision)"
            lattices[subdivision] = (buffer, indices.count)
        }
        latticeIndicesBySubdivision = lattices

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .always
        depthDescriptor.isDepthWriteEnabled = false
        depthState = metalDevice.makeDepthStencilState(descriptor: depthDescriptor)!
    }

    func states(for surface: Surface) -> States {
        statesBySurface[surface]!
    }

    /// The indices of a patch of `subdivision` quads a side, one of
    /// `subdivisions`.
    func latticeIndices(subdivision: Int) -> (buffer: MTLBuffer, count: Int) {
        latticeIndicesBySubdivision[subdivision]!
    }

    /// How finely a tile of `zoom` is divided. The plane needs no
    /// division, a quad is flat. On the sphere and through the unfurl a
    /// tile curves, and the coarser it is the more of the sphere it
    /// spans: the whole world at zoom 0 takes the whole lattice, and each
    /// zoom deeper half as many quads a side, four at the least.
    static func subdivision(zoom: Int, surface: Surface) -> Int {
        guard surface != .flat else { return 1 }
        return max(4, latticeSide >> min(max(zoom, 0), 30))
    }

    /// The triangles of a patch of `subdivision` quads a side, over the
    /// points of the one lattice of `latticeSide` quads a side, which the
    /// vertex stage places by their index alone.
    static func latticeIndices(subdivision: Int) -> [UInt16] {
        let step = latticeSide / subdivision
        let points = latticeSide + 1
        var indices: [UInt16] = []
        indices.reserveCapacity(subdivision * subdivision * 6)
        for row in 0 ..< subdivision {
            for column in 0 ..< subdivision {
                let topLeft = UInt16(row * step * points + column * step)
                let topRight = topLeft + UInt16(step)
                let bottomLeft = topLeft + UInt16(step * points)
                let bottomRight = bottomLeft + UInt16(step)
                indices.append(contentsOf: [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight])
            }
        }
        return indices
    }
}

/// Mirrors `TileGridTile` in TileGrid.metal: one tile of the frame.
struct TileGridTileGPU: Equatable {
    static let selectedFlag: UInt32 = 1
    static let fillOnlyFlag: UInt32 = 2

    var flatOrigin: SIMD2<Float>
    var flatSize: Float
    var referenceWorldX: Float
    var uvOrigin: SIMD2<Float>
    var uvScale: Float
    var flags: UInt32
}

/// Mirrors `TileGridGlyph` in TileGrid.metal: one corner of a glyph.
struct TileGridGlyphGPU: Equatable {
    var tileUV: SIMD2<Float>
    var atlasUV: SIMD2<Float>
    var tileIndex: UInt32
    var minimumEmPx: Float
}

/// Mirrors `TileGridFrame` in TileGrid.metal: the frame's look.
struct TileGridFrameUniform {
    var lineColor: SIMD4<Float>
    var selectedFillColor: SIMD4<Float>
    var labelColor: SIMD4<Float>
    var labelHaloColor: SIMD4<Float>
    var halfLineWidthPx: Float
    var minimumTilePx: Float
    var depth: Float
    var atlasDistanceRange: Float
    var atlasEmTexels: Float
    var haloWidthPx: Float
    var haloPass: Float
    var padding: Float = 0
}

/// The clip-space depth the tile grid is given. The grid is not tested
/// against any depth, so this only keeps it within the clip volume: just
/// inside the far plane, as the ground's own layers are.
enum TileGridDepth {
    static let depth: Float = 1 - GlobeSurfaceDepthRank.realGeometryRank * GlobeSurfaceDepthRank.layerDepthStep
}

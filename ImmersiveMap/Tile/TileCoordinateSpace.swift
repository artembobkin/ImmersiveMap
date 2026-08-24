// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The single source of truth for the tile geometry Y axis.
///
/// Four spaces exist, and every mirror bug this engine has shipped was an
/// unmarked handoff between the first two:
///
/// - **Tile space** (raw MVT): x grows east, y grows SOUTH from the north
///   edge, 0...4096. This is the working space of the whole Parse layer:
///   the decoder output, the road pre-pass and its clipper and stitcher,
///   label anchors and road-label paths, decoration builder inputs, and the
///   debug grid stamps all speak it, because the data itself (tile bytes,
///   the pipeline's GeoJSON) speaks it.
/// - **Render space**: y grows NORTH from the south edge, `4096 - y`. It
///   exists only as the vertex storage and GPU contract (`ParsedPolygon`,
///   `TileVertexIn`, extrusion meshes, `TileLocalClipMath` bounds,
///   `Tile.metal`'s `localPosition`), matching the y-up flat render world.
///   It is entered at exactly ONE named point per geometry kind: inside
///   `ParseLine`'s precompute for lines, at `ParsePolygon`'s tessellation
///   for polygon fills, at `BuildingExtrusionCandidate` construction for
///   the extrusion path, and at the top of each decoration builder, always
///   through the helpers below and never as an inline subtraction.
/// - **Tile UV**: v = y / 4096, the same axis as tile space. Labels divide
///   and never flip; the flat point kernel un-flips v into the y-up world,
///   the globe kernel consumes v directly.
/// - **World spaces**: normalized world mercator y grows south (0 is the
///   north pole side); the flat render world is y-up via the
///   `tilesCount - y - 1` tile-row flip in `ImmersiveMapProjection`.
///
/// History, so the next reader believes the ceremony: the junction kerb
/// shipped mirrored about the tile mid-line (prepared format v46 -> v47),
/// roads shipped clipped against a mirror image of every carriageway
/// surface (v53 -> v54), and the debug grid stamps shipped pointing at the
/// mirrored half of the tile. All three were silent tile-to-render handoffs,
/// and two hid behind test fixtures symmetric about the tile centre.
enum TileCoordinateSpace {
    static let tileExtent: Float = 4096
    static let tileExtentDouble: Double = 4096
    static let tileExtentInt: Int = 4096

    /// Tile space -> render space. The reflection is its own inverse; the
    /// two names exist so a call site says which way it is going.
    @inline(__always)
    static func renderY(_ tileY: Float) -> Float {
        tileExtent - tileY
    }

    @inline(__always)
    static func renderPoint(_ point: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(point.x, tileExtent - point.y)
    }

    static func renderPoints(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        points.map(renderPoint)
    }

    /// Render space -> tile space: the same reflection, named for the reader.
    @inline(__always)
    static func tileY(_ renderY: Float) -> Float {
        tileExtent - renderY
    }

    /// The shared vertex quantizer (round and clamp to the Int16 the vertex
    /// format stores): one copy instead of one per decoration builder.
    @inline(__always)
    static func quantized(_ point: SIMD2<Float>) -> SIMD2<Int16> {
        SIMD2<Int16>(Int16(clamping: Int(point.x.rounded())),
                     Int16(clamping: Int(point.y.rounded())))
    }
}

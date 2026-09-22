// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// One ground/road geometry vertex as the tile shaders consume it. The memory
/// layout is a binding contract shared by three parties: `TilePipeline`'s
/// vertex descriptor (attribute offsets and stride), the arena image format
/// (span strides, see `TileArenaImageMath`), and the parser that emits the
/// vertices. Changing the layout is therefore a shader change and a
/// prepared-cache format change (bump `PreparedTileDiskCaching.preparedFormatVersion`).
struct TileVertexIn: Sendable {
    let position: SIMD2<Int16>
    let styleIndex: UInt8
    /// Analytic line antialiasing: the signed distance from the line's
    /// centerline, normalized so the extruded geometry rim is ±`Int8.max`.
    /// Where the styled edge sits inside that field, and whether the style is
    /// a line at all, lives in the per-style `TileLineStyle`.
    let lineDistance: Int8
    /// Longitudinal line parameter, interpreted by the style:
    /// - a solid style reads it as the signed distance past a free butt end,
    ///   in feather units, normalized so one feather is `Int16.max`, and
    ///   saturated everywhere the end must stay hard;
    /// - a point-dashed style (`TileLineStyle.dashLengthPoints > 0`) reads it
    ///   as the arc length along the line in half tile units, from which the
    ///   fragment shader cuts the dash pattern at a stable on-screen size.
    /// Attribute-less polygon geometry saturates it, so a polygon that shares
    /// a line style (road decorations) reads as line interior.
    let lineParameter: Int16
    /// A deferred ribbon's extrusion direction, snorm (`Int8.max` is one):
    /// `position` is then a point of the centreline and the flat vertex
    /// shader moves the vertex along this by the style's width on screen,
    /// so the ribbon is as wide as it should be at every distance and
    /// never a sub-pixel sliver (`ParsedPolygon.lineNormals`). Zero on a
    /// centreline hub and on every vertex whose position is final: the
    /// pre-extruded ribbons of the sphere-era tiles and all fills.
    ///
    /// A fill of the footprint fade band (`LowZoomOverviewFade.footprintFadeMask`)
    /// carries its polygon's footprint radius here instead, see
    /// `footprintRadiusNormal`.
    let normal: SIMD2<Int8>

    /// A polygon's footprint radius packed into the `normal` bytes: quarter
    /// tile units as two base-128 digits, high then low, so the snorm fetch
    /// hands the shader two exact integers over 127. Holds up to 4095 tile
    /// units, a whole tile. Zero: no radius, the fill never fades.
    static func footprintRadiusNormal(radiusUnits: Float) -> SIMD2<Int8> {
        let quarterUnits = Int(min(max((radiusUnits * 4).rounded(), 0), 16383))
        return SIMD2<Int8>(Int8(quarterUnits / 128), Int8(quarterUnits % 128))
    }

    init(position: SIMD2<Int16>,
         styleIndex: UInt8,
         lineDistance: Int8 = 0,
         lineParameter: Int16 = Int16.max,
         normal: SIMD2<Int8> = .zero) {
        self.position = position
        self.styleIndex = styleIndex
        self.lineDistance = lineDistance
        self.lineParameter = lineParameter
        self.normal = normal
    }
}

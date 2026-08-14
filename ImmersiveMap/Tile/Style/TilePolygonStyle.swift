// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct TilePolygonStyle {
    let color: SIMD4<Float>
}

/// Per-style line rendering parameters, uploaded alongside `TilePolygonStyle`
/// and indexed by the same style index. The memory layout is a binding
/// contract with `Tile.metal`'s `LineStyle` struct and an arena span stride;
/// changing it is a prepared-cache format change (bump
/// `PreparedTileDiskCaching.preparedFormatVersion`).
struct TileLineStyle {
    /// Point-locked visible full width; zero keeps the world-locked width the
    /// tessellator baked. See `LineRenderPass.lineWidthPoints`.
    var widthPoints: Float
    /// Point-locked dash pattern, resolved per fragment from the vertices'
    /// arc-length parameter; zero dash length draws solid.
    var dashLengthPoints: Float
    var dashGapPoints: Float
    /// Where the styled edge sits inside the extruded distance field (styled
    /// half-width over extruded half-width, 0...1). Zero marks a non-line
    /// style: the shader skips line coverage entirely for it.
    var edgeThreshold: Float

    static let polygon = TileLineStyle(widthPoints: 0,
                                       dashLengthPoints: 0,
                                       dashGapPoints: 0,
                                       edgeThreshold: 0)
}

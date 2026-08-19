// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct TilePolygonStyle {
    let color: SIMD4<Float>
    /// The street-palette counterpart of `color`. The ground palette hands
    /// over from the overview set (soft-biome greens, saturated globe water)
    /// to the street set continuously in camera zoom: the shader lerps
    /// between the two baked colors with a per-frame blend, so the rendered
    /// color is identical on both sides of every tile swap and no zoom
    /// boundary can flip the map's look. Styles with no street counterpart
    /// bake the same color twice. The memory layout is a binding contract
    /// with the `Style` structs in Tile.metal and TileExtruded.metal and an
    /// arena span stride; changing it is a prepared-cache format change.
    let streetColor: SIMD4<Float>

    init(color: SIMD4<Float>, streetColor: SIMD4<Float>? = nil) {
        self.color = color
        self.streetColor = streetColor ?? color
    }
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
    /// Floor for a world-locked width, in layout points: the visible width is
    /// the world width or this, whichever is wider, so a road class never
    /// thins into an unreadable hairline at region zooms yet still grows with
    /// the world at street level. Zero disables the floor; ignored when
    /// `widthPoints` locks the width outright.
    var minimumWidthPoints: Float
    /// Non-zero when the dash pattern is world-locked: `dashLengthPoints` and
    /// `dashGapPoints` are then tile units, not points, and the shader cuts
    /// the pattern from arc length with no point-to-unit conversion. Paint on
    /// the ground (a lane divider) is part of the surface: its period is a
    /// length in metres, so it must not re-flow when the camera zooms or the
    /// engine swaps the tile level that serves the road.
    var dashInTileUnits: Float
    /// Ceiling for a world-locked width, in layout points: the visible width
    /// is the world width or this, whichever is narrower. A road is a readable
    /// symbol at region zooms and becomes its true surface only once the
    /// world width has shrunk below the symbol on screen, which happens
    /// continuously with the camera instead of doubling at every tile level.
    /// Zero disables the ceiling; ignored when `widthPoints` locks the width.
    var maximumWidthPoints: Float
    /// Reserved; keeps the stride stable for future line parameters.
    var reserved2: Float = 0

    init(widthPoints: Float,
         dashLengthPoints: Float,
         dashGapPoints: Float,
         edgeThreshold: Float,
         minimumWidthPoints: Float = 0,
         dashInTileUnits: Bool = false,
         maximumWidthPoints: Float = 0) {
        self.widthPoints = widthPoints
        self.dashLengthPoints = dashLengthPoints
        self.dashGapPoints = dashGapPoints
        self.edgeThreshold = edgeThreshold
        self.minimumWidthPoints = minimumWidthPoints
        self.dashInTileUnits = dashInTileUnits ? 1 : 0
        self.maximumWidthPoints = maximumWidthPoints
    }

    static let polygon = TileLineStyle(widthPoints: 0,
                                       dashLengthPoints: 0,
                                       dashGapPoints: 0,
                                       edgeThreshold: 0)
}

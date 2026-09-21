// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct TilePolygonStyle {
    /// The memory layout is a binding contract with the `Style` structs in
    /// Tile.metal and TileExtruded.metal and an arena span stride; changing
    /// it is a prepared-cache format change.
    let color: SIMD4<Float>
    /// The footprint fade's target: where a screen pixel covers more ground
    /// than the style's detail can resolve (a tilted far range, a coarse
    /// tile minified), the fragment blends the fill toward this colour, so
    /// neighbouring fills converge on one tone instead of flickering between
    /// samples. The alpha is the fade strength: 1 fades fully to the target,
    /// 0 (the default) never fades. See `GroundFootprintFade`.
    let farColor: SIMD4<Float>

    init(color: SIMD4<Float>, farColor: SIMD4<Float>? = nil) {
        self.color = color
        self.farColor = farColor ?? SIMD4<Float>(0, 0, 0, 0)
    }
}

/// Per-style line rendering parameters, uploaded alongside `TilePolygonStyle`
/// and indexed by the same style index. The memory layout is a binding
/// contract with `Tile.metal`'s `LineStyle` struct and an arena span stride;
/// changing it is a prepared-cache format change (bump
/// `PreparedTileDiskCaching.preparedFormatVersion`).
struct TileLineStyle {
    /// Point-locked visible full width; zero keeps the world-locked width the
    /// tessellator baked. See `LinePass.lineWidthPoints`.
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
    /// The styled half-width in tile units, what a deferred ribbon's vertex
    /// shader extrudes a world-locked style by (`TileVertexIn.normal`).
    var halfWidthUnits: Float
    /// The camera zoom a point-locked width is frozen on the ground from:
    /// up to it the width holds in points, past it the width is what those
    /// points covered on the ground at that zoom, so it doubles on screen
    /// with every zoom level like the map around it. Zero: the points hold
    /// at every zoom. See `LinePass.pointWidthWorldLockZoom`.
    var worldLockZoom: Float
    /// The zoom ramp of a point-locked width; see `LinePass.WidthRamp`. An
    /// end zoom of zero is no ramp, and the start alpha is then one.
    var rampStartWidthPoints: Float
    var rampStartZoom: Float
    var rampEndZoom: Float
    var rampStartAlpha: Float

    init(widthPoints: Float,
         dashLengthPoints: Float,
         dashGapPoints: Float,
         edgeThreshold: Float,
         minimumWidthPoints: Float = 0,
         dashInTileUnits: Bool = false,
         maximumWidthPoints: Float = 0,
         halfWidthUnits: Float = 0,
         worldLockZoom: Float = 0,
         widthRamp: LinePass.WidthRamp? = nil) {
        self.rampStartWidthPoints = widthRamp?.startWidthPoints ?? 0
        self.rampStartZoom = widthRamp?.startZoom ?? 0
        self.rampEndZoom = widthRamp?.endZoom ?? 0
        self.rampStartAlpha = widthRamp?.startAlpha ?? 1
        self.halfWidthUnits = halfWidthUnits
        self.worldLockZoom = worldLockZoom
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

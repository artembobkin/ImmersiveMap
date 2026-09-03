// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The per-draw uniforms of the tile ground shaders, shared by the flat
/// surface, the sphere surface and the atlas bake; the layouts mirror the
/// structs of the same names in TileShading.h.
struct TileOverviewFadeUniform {
    var overviewAlpha: Float
    var roadAlpha: Float
    var landuseAlpha: Float
    /// Converts the per-style point-locked line widths into the pixels the
    /// shader's coverage math runs in.
    var pixelsPerPoint: Float
    /// See `LowZoomOverviewFade.roadSurfaceBlend`. Zero on the globe and in
    /// the atlas: at overview zooms every road is a symbol.
    var roadSurfaceBlend: Float = 0
    /// See `LowZoomOverviewFade.roadMarkingAlpha`: road markings come in
    /// over their own camera-zoom band, above the one the carriageway widths
    /// morph over. Zero on the globe and in the atlas: no road is painted yet.
    var roadMarkingAlpha: Float = 0
    /// See `LowZoomOverviewFade.classFadeMask`: the live camera zoom the
    /// per-class road fade is evaluated against.
    var cameraZoom: Float

    init(overviewAlpha: Float,
         roadAlpha: Float,
         landuseAlpha: Float,
         pixelsPerPoint: Float,
         roadSurfaceBlend: Float = 0,
         roadMarkingAlpha: Float = 0,
         cameraZoom: Float) {
        self.overviewAlpha = overviewAlpha
        self.roadAlpha = roadAlpha
        self.landuseAlpha = landuseAlpha
        self.pixelsPerPoint = pixelsPerPoint
        self.roadSurfaceBlend = roadSurfaceBlend
        self.roadMarkingAlpha = roadMarkingAlpha
        self.cameraZoom = cameraZoom
    }
}

/// Per-draw dash scale: tile units per layout point at the tile's nominal
/// display scale (see `LineDashNominalScale`).
struct LineDashUniform {
    var unitsPerPoint: Float
}

/// Per-frame overview-to-street palette blend, from camera zoom.
struct StreetPaletteUniform {
    var blend: Float
}

/// Mirror of `FillOutlineUniform` in Tile.metal (fragment buffer 9 of the
/// flat fill-outline pipeline): the drawable size in pixels, which places
/// the interpolated clip position of an outline edge in the fragment's
/// pixel space.
struct TileFillOutlineUniform {
    var viewportSizePx: SIMD2<Float>
}

/// Mirror of `FootprintFadeUniform` in TileShading.h (fragment buffer 10 of
/// the flat fills pipelines): the source tile's units per world unit and the
/// footprint band of `GroundFootprintFade`.
struct TileFootprintFadeUniform {
    var unitsPerWorld: Float
    var startUnits: Float
    var endUnits: Float
    var padding: Float = 0

    init(unitsPerWorld: Float,
         startUnits: Float = GroundFootprintFade.startUnits,
         endUnits: Float = GroundFootprintFade.endUnits) {
        self.unitsPerWorld = unitsPerWorld
        self.startUnits = startUnits
        self.endUnits = endUnits
    }
}

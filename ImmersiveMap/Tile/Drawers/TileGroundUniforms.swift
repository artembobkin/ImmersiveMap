// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

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
    /// The drawable in pixels, what the deferred ribbons' vertex stage
    /// converts a tile unit's clip-space span into pixels with (Tile.metal).
    /// Zero on the sphere and wherever no ribbon is deferred.
    var viewportSizePx: SIMD2<Float>
    /// The view depth of the ground point at the centre of the screen, what
    /// a point-locked deferred ribbon's width is stated at
    /// (`tilePointWidthPerspectiveScale` in TileShading.h). Zero: the width
    /// holds in pixels at every depth.
    var pointWidthReferenceDepth: Float = 0
    /// The roads' thinness fade (`RoadThinnessFade`), as widths on screen
    /// in pixels. A zero opaque width turns it off.
    var roadFadeGoneWidthPx: Float = 0
    var roadFadeOpaqueWidthPx: Float = 0
    /// The footprint fade of the building fills (`tileFootprintAlpha`), the
    /// debug panel's two footprint areas in square pixels. A zero opaque
    /// area turns it off.
    var footprintGoneAreaPx: Float = 0
    var footprintOpaqueAreaPx: Float = 0

    init(overviewAlpha: Float,
         roadAlpha: Float,
         landuseAlpha: Float,
         pixelsPerPoint: Float,
         roadSurfaceBlend: Float = 0,
         roadMarkingAlpha: Float = 0,
         cameraZoom: Float,
         viewportSizePx: SIMD2<Float> = .zero,
         pointWidthReferenceDepth: Float = 0,
         roadThinnessFade: RoadThinnessFade = .off,
         footprintGoneAreaPx: Float = 0,
         footprintOpaqueAreaPx: Float = 0) {
        self.overviewAlpha = overviewAlpha
        self.roadAlpha = roadAlpha
        self.landuseAlpha = landuseAlpha
        self.pixelsPerPoint = pixelsPerPoint
        self.roadSurfaceBlend = roadSurfaceBlend
        self.roadMarkingAlpha = roadMarkingAlpha
        self.cameraZoom = cameraZoom
        self.viewportSizePx = viewportSizePx
        self.pointWidthReferenceDepth = pointWidthReferenceDepth
        self.roadFadeGoneWidthPx = roadThinnessFade.goneWidthPixels
        self.roadFadeOpaqueWidthPx = roadThinnessFade.opaqueWidthPixels
        self.footprintGoneAreaPx = max(footprintGoneAreaPx, 0)
        self.footprintOpaqueAreaPx = max(footprintOpaqueAreaPx, self.footprintGoneAreaPx)
    }
}

/// Per-draw dash scale: tile units per layout point at the tile's nominal
/// display scale (see `LineDashNominalScale`).
struct LineDashUniform {
    var unitsPerPoint: Float
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


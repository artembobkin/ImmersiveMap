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
    /// See `LowZoomOverviewFade.roadMarkingAlpha`: road markings come in
    /// over their own camera-zoom band. Zero on the globe and in the atlas:
    /// no road is painted yet.
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
    /// The roads' thinness fade (`RoadThinnessFade`), as a width on screen
    /// in pixels. Zero turns it off.
    var roadFadeOpaqueWidthPx: Float = 0
    /// The footprint fade of the building fills (`tileFootprintAlpha`), the
    /// debug panel's two footprint areas in square pixels. A zero opaque
    /// area turns it off.
    var footprintGoneAreaPx: Float = 0
    var footprintOpaqueAreaPx: Float = 0
    /// The pixels one world unit of ground spans across the view at the
    /// centre of the screen: what turns a point width there into the width
    /// on the ground every road of the style lies at
    /// (`tilePointWidthPerspectiveScale`). Zero: the distance alone.
    var pointWidthCentrePixelsPerWorldUnit: Float = 0
    /// The camera matrix's columns of the two ground axes, their x, y and w
    /// rows, as the shader's two packed triples: what a ground direction
    /// becomes in clip space (`tileGroundDirectionalCompression`).
    var groundAxisXClipX: Float = 0
    var groundAxisXClipY: Float = 0
    var groundAxisXClipW: Float = 0
    var groundAxisYClipX: Float = 0
    var groundAxisYClipY: Float = 0
    var groundAxisYClipW: Float = 0

    init(overviewAlpha: Float,
         roadAlpha: Float,
         landuseAlpha: Float,
         pixelsPerPoint: Float,
         roadMarkingAlpha: Float = 0,
         cameraZoom: Float,
         viewportSizePx: SIMD2<Float> = .zero,
         pointWidthReferenceDepth: Float = 0,
         roadThinnessFade: RoadThinnessFade = .off,
         cameraMatrix: matrix_float4x4? = nil,
         footprintGoneAreaPx: Float = 0,
         footprintOpaqueAreaPx: Float = 0) {
        self.overviewAlpha = overviewAlpha
        self.roadAlpha = roadAlpha
        self.landuseAlpha = landuseAlpha
        self.pixelsPerPoint = pixelsPerPoint
        self.roadMarkingAlpha = roadMarkingAlpha
        self.cameraZoom = cameraZoom
        self.viewportSizePx = viewportSizePx
        self.pointWidthReferenceDepth = pointWidthReferenceDepth
        self.roadFadeOpaqueWidthPx = roadThinnessFade.opaqueWidthPixels
        if let cameraMatrix {
            let xAxis = cameraMatrix.columns.0
            let yAxis = cameraMatrix.columns.1
            self.pointWidthCentrePixelsPerWorldUnit = Self.centrePixelsPerWorldUnitAcrossTheView(
                xAxis: xAxis, yAxis: yAxis, viewportSizePx: viewportSizePx, referenceDepth: pointWidthReferenceDepth)
            (groundAxisXClipX, groundAxisXClipY, groundAxisXClipW) = (xAxis.x, xAxis.y, xAxis.w)
            (groundAxisYClipX, groundAxisYClipY, groundAxisYClipW) = (yAxis.x, yAxis.y, yAxis.w)
        }
        self.footprintGoneAreaPx = max(footprintGoneAreaPx, 0)
        self.footprintOpaqueAreaPx = max(footprintOpaqueAreaPx, self.footprintGoneAreaPx)
    }
}

extension TileOverviewFadeUniform {
    /// The pixels a world unit of ground spans at the centre of the screen
    /// along the ground direction that runs across the view, the one a step
    /// along which changes no depth. It is the scale the perspective leaves
    /// undistorted, so it is what a road along the view is measured in.
    /// Under a camera looking straight down no direction changes the depth
    /// and every one of them is across the view.
    static func centrePixelsPerWorldUnitAcrossTheView(xAxis: SIMD4<Float>,
                                                      yAxis: SIMD4<Float>,
                                                      viewportSizePx: SIMD2<Float>,
                                                      referenceDepth: Float) -> Float {
        guard referenceDepth > 0 else { return 0 }
        let depthGradient = SIMD2<Float>(xAxis.w, yAxis.w)
        let across = simd_length(depthGradient) > 1e-9
            ? simd_normalize(SIMD2<Float>(-depthGradient.y, depthGradient.x))
            : SIMD2<Float>(1, 0)
        let clipStep = SIMD2<Float>(xAxis.x, xAxis.y) * across.x + SIMD2<Float>(yAxis.x, yAxis.y) * across.y
        let pixels = simd_length(clipStep * viewportSizePx * 0.5) / referenceDepth
        return pixels.isFinite ? pixels : 0
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


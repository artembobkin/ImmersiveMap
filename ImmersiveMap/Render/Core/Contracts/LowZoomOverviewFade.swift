// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  LowZoomOverviewFade.swift
//  ImmersiveMap
//

import simd

enum LowZoomOverviewFade {
    enum Kind {
        case overviewFeatures
        case roads
        case landuse
    }

    static let overviewStartZoom: Double = 0.0
    static let overviewEndZoom: Double = 1.0
    /// Roads fade in from the first zoom the style shows them (tile z5, the
    /// motorway skeleton; trunks join at z6 when the source ships them).
    static let roadStartZoom: Double = 5.0
    static let roadEndZoom: Double = 6.0
    static let landuseStartZoom: Double = 13.0
    static let landuseEndZoom: Double = 14.0
    /// The overview-to-street ground palette handover. Continuous in camera
    /// zoom by design: the tiles bake both palettes per style and the shader
    /// lerps, so the rendered ground color never steps at a tile-zoom
    /// boundary. The band brackets where the ground data itself hands over
    /// (WorldCover biomes end at tile z9, OSM landcover starts at z10).
    static let streetPaletteStartZoom: Double = 8.0
    static let streetPaletteEndZoom: Double = 11.5

    /// How far a road has become its true surface rather than a symbol, in
    /// camera zoom. Below the start a road draws at its symbol width (the
    /// style's point ceiling, constant on screen); above the end at its real
    /// carriageway width on the ground; between, the edge morphs from one to
    /// the other. Continuous in camera zoom by construction, so the width never
    /// steps at a tile level: the tile level swap changes nothing about what
    /// is drawn, only the geometry it is drawn from.
    static let roadSurfaceStartZoom: Double = 14.0
    static let roadSurfaceEndZoom: Double = 16.0

    /// Where road markings fade in, in camera zoom.
    ///
    /// Paint is a length on the ground, so the band decides how small a dash
    /// is allowed to get before it is drawn: three metres is about one point
    /// across a z14 frame and two across a z15 one. The band is continuous in
    /// camera zoom, so nothing pops when the engine swaps the tile level
    /// serving a street.
    ///
    /// It overlaps the width morph (`roadSurfaceStartZoom`), which means the
    /// paint arrives while the widest carriageways are still drawn at their
    /// symbol width: the lateral offsets of the lane lines are measured
    /// against the true carriageway, so on a road whose true width is well
    /// past the symbol ceiling the outer lines sit a little outside the
    /// drawn edge until the morph catches up. A centre divider is on the
    /// centreline and is unaffected.
    static let roadMarkingStartZoom: Double = 14.0
    static let roadMarkingEndZoom: Double = 15.0

    static func roadMarkingAlpha(for zoom: Double) -> Float {
        let progress = Float((zoom - roadMarkingStartZoom) / (roadMarkingEndZoom - roadMarkingStartZoom))
        let clamped = simd_clamp(progress, 0.0, 1.0)
        return clamped * clamped * (3.0 - 2.0 * clamped)
    }

    static func roadSurfaceBlend(for zoom: Double) -> Float {
        let progress = Float((zoom - roadSurfaceStartZoom) / (roadSurfaceEndZoom - roadSurfaceStartZoom))
        let clamped = simd_clamp(progress, 0.0, 1.0)
        return clamped * clamped * (3.0 - 2.0 * clamped)
    }

    static func alpha(for zoom: Double, kind: Kind = .overviewFeatures) -> Float {
        let range: (start: Double, end: Double)
        switch kind {
        case .overviewFeatures:
            range = (overviewStartZoom, overviewEndZoom)
        case .roads:
            range = (roadStartZoom, roadEndZoom)
        case .landuse:
            range = (landuseStartZoom, landuseEndZoom)
        }

        guard range.end > range.start else {
            return zoom >= range.end ? 1.0 : 0.0
        }

        let progress = Float((zoom - range.start) / (range.end - range.start))
        let clamped = simd_clamp(progress, 0.0, 1.0)
        return clamped * clamped * (3.0 - 2.0 * clamped)
    }

    static func streetPaletteBlend(for zoom: Double) -> Float {
        let progress = Float((zoom - streetPaletteStartZoom)
            / (streetPaletteEndZoom - streetPaletteStartZoom))
        let clamped = simd_clamp(progress, 0.0, 1.0)
        return clamped * clamped * (3.0 - 2.0 * clamped)
    }
}

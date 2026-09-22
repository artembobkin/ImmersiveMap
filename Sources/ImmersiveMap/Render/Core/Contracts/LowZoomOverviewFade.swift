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

    /// Where road markings fade in, in camera zoom.
    ///
    /// Paint is a length on the ground, so the band decides how small a dash
    /// is allowed to get before it is drawn. Below camera zoom 15 there is
    /// NO paint at all: the streets read as a network, not a surface, and a
    /// three-metre dash is around a point across the frame there, noise
    /// rather than marking. From 15 the paint fades in over a short band,
    /// continuous in camera zoom so nothing pops when the engine swaps the
    /// tile level serving a street.
    ///
    /// The band starts at the zoom the roads' symbols are frozen on the
    /// ground by default (the theme's world lock), so the paint arrives on
    /// a road that is already a width on the ground: the lane lines are
    /// laid across the symbol's ground width, and from here the road and
    /// its paint grow together.
    static let roadMarkingStartZoom: Double = 15.0
    static let roadMarkingEndZoom: Double = 15.4

    static func roadMarkingAlpha(for zoom: Double) -> Float {
        let progress = Float((zoom - roadMarkingStartZoom) / (roadMarkingEndZoom - roadMarkingStartZoom))
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

    /// The per-class road fade. A road class appears at the tile zoom that
    /// first ships it readably, and it comes in over the following zoom
    /// level instead of popping with the tile: the style bakes a mask of
    /// `classFadeMaskBase` plus the start zoom, and the shader evaluates
    /// the band against the live camera zoom, so the fade is continuous with
    /// the camera and shared by the flat and the atlas path. Masks below the
    /// base keep their fixed bands (`Kind`, the markings).
    static let classFadeMaskBase: Float = 10.0

    /// The footprint fade band: a fill carrying this mask takes its alpha
    /// from its polygon's footprint on screen (`BuildingFootprintFade`, the
    /// building fills), and the parser bakes the polygon's footprint radius
    /// into its vertices for it (`TileVertexIn.footprintRadiusNormal`). No
    /// zoom fade of its own.
    static let footprintFadeMask: Float = 5.0

    static func isFootprintFadeBand(mask: Float) -> Bool {
        mask >= 4.5 && mask < 9.5
    }
    static let classFadeBandZooms: Double = 1.0

    static func classFadeMask(startZoom: Int) -> Float {
        classFadeMaskBase + Float(startZoom)
    }

    static func classFadeAlpha(for zoom: Double, startZoom: Int) -> Float {
        let progress = Float((zoom - Double(startZoom)) / classFadeBandZooms)
        let clamped = simd_clamp(progress, 0.0, 1.0)
        return clamped * clamped * (3.0 - 2.0 * clamped)
    }
}

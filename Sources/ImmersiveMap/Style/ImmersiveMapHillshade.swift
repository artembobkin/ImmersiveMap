// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// How the ground's slopes are shaded where the relief stands
/// (`TileSettings.GroundReliefSettings`), stated by the style like every
/// other colour of the map: a slope turned toward the light takes the
/// highlight, a slope turned away from it the shadow, and level ground
/// keeps its own colour. The light is the scene's
/// (`SceneLightSettings.direction`, the sun the buildings cast their
/// shadows by), and the slopes are the terrain's own, read per pixel from
/// the terrain tiles, so the shading is finer than the relief's grid.
/// Drawn at frame time, never baked into the prepared tiles, so a change
/// needs no re-parse.
public struct ImmersiveMapHillshade: Equatable, Sendable {
    /// How strongly the slopes are shaded: 0 draws none, 1 takes a slope
    /// that faces the light square on, or turns away from it entirely, all
    /// the way to its colour. 0.76 by default.
    public var intensity: Float
    /// The colour a slope turned away from the light is drawn toward, RGBA
    /// in 0...1. The alpha caps how far, 0.34 by default.
    public var shadowColor: SIMD4<Float>
    /// The colour a slope turned toward the light is drawn toward, RGBA in
    /// 0...1. The alpha caps how far, 0.18 by default: the light side of a
    /// mountain keeps the map's colour, the shade side carries the form.
    public var highlightColor: SIMD4<Float>
    /// Where the shading starts to fade, in metres from the eye, by the
    /// camera zoom (`ImmersiveMapZoomCurve`, read at the zoom the relief
    /// stands by): 60 km at zoom 10, 4 km at 14 and 250 m at 18 by
    /// default, halving with every zoom between the stops as the map's
    /// scale does (the curve runs geometrically), which keeps the fade at
    /// about the same place on screen. The shading is for the ground near
    /// the camera. Far off, a pixel spans many of the terrain's heights
    /// and the slopes it falls on change from frame to frame, so the
    /// shading there only shimmers, and the far ground is read by its
    /// outline anyway. In metres, like the ground fog's lengths, so the
    /// same curve means the same ground on every screen and at every
    /// pitch.
    public var fadeStartMeters: ImmersiveMapZoomCurve
    /// Where the shading has faded out, in the same metres by the zoom:
    /// twice the start by default (120 km at zoom 10 to 500 m at 18). Past
    /// it no slope is shaded, and the ground there costs nothing for it.
    /// Raise both to shade further out, lower them if the far ground still
    /// shimmers.
    public var fadeEndMeters: ImmersiveMapZoomCurve

    public init(intensity: Float = 0.76,
                shadowColor: SIMD4<Float> = SIMD4<Float>(0.05, 0.07, 0.15, 0.34),
                highlightColor: SIMD4<Float> = SIMD4<Float>(1, 0.98, 0.92, 0.18),
                fadeStartMeters: ImmersiveMapZoomCurve = [10: 60_000, 14: 4000, 18: 250],
                fadeEndMeters: ImmersiveMapZoomCurve = [10: 120_000, 14: 8000, 18: 500]) {
        self.intensity = intensity
        self.shadowColor = shadowColor
        self.highlightColor = highlightColor
        self.fadeStartMeters = fadeStartMeters
        self.fadeEndMeters = fadeEndMeters
    }

    /// No shading.
    public static let none = ImmersiveMapHillshade(intensity: 0)
}

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
    /// the way to its colour.
    public var intensity: Float
    /// The colour a slope turned away from the light is drawn toward, RGBA
    /// in 0...1. The alpha caps how far.
    public var shadowColor: SIMD4<Float>
    /// The colour a slope turned toward the light is drawn toward, RGBA in
    /// 0...1. The alpha caps how far.
    public var highlightColor: SIMD4<Float>
    /// Where the shading starts to fade, from the eye, in the eye's
    /// distances to the point it looks at: 2 by default. The shading is
    /// for the ground near the camera. Far off, a pixel spans many of the
    /// terrain's heights and the slopes it falls on change from frame to
    /// frame, so the shading there only shimmers, and the far ground is
    /// read by its outline anyway. Measured in the eye's distances, the
    /// fade sits at the same place on screen at every zoom.
    public var fadeStartCameraDistances: Float
    /// Where the shading has faded out, in the same distances: 4 by
    /// default. Past it no slope is shaded, and the ground there costs
    /// nothing for it. Raise both to shade further out, lower them if the
    /// far ground still shimmers.
    public var fadeEndCameraDistances: Float

    public init(intensity: Float = 1,
                shadowColor: SIMD4<Float> = SIMD4<Float>(0.05, 0.07, 0.15, 0.55),
                highlightColor: SIMD4<Float> = SIMD4<Float>(1, 0.98, 0.92, 0.3),
                fadeStartCameraDistances: Float = 2,
                fadeEndCameraDistances: Float = 4) {
        self.intensity = intensity
        self.shadowColor = shadowColor
        self.highlightColor = highlightColor
        self.fadeStartCameraDistances = fadeStartCameraDistances
        self.fadeEndCameraDistances = fadeEndCameraDistances
    }

    /// No shading.
    public static let none = ImmersiveMapHillshade(intensity: 0)
}

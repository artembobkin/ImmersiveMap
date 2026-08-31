// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Whether this frame lights the globe surface in one deferred pass.
///
/// On the pure sphere at the plain palette, everything `globeSurfaceShade`
/// does to a colour is affine: the day/night factor multiplies, the rim
/// light and the limb glow add, the horizon fog's strength is the transition
/// and so zero, and the deep-space tone is inactive. An affine transform
/// commutes exactly with alpha blending, so the ground layers can blend
/// unlit and the `globeSurfaceLighting` layer applies the light once per
/// pixel instead of once per layer. The moment any non-affine piece wakes
/// up (the unfurl brings the fog and the morphed silhouette, the deep tone
/// brings its power curve below zoom 2), every layer goes back to lighting
/// itself inline and the pass draws nothing, so the picture is the shader's
/// own in both worlds.
///
/// One rule, consulted by the placeholder fill, the tile geometry and the
/// lighting subsystem alike, so the three can never disagree within a frame.
enum GlobeSurfaceLightingPath {
    static func isDeferred(renderSurfaceMode: ViewMode, transition: Float, zoom: Double) -> Bool {
        renderSurfaceMode == .spherical
            && transition == 0
            && GlobeSurfaceToneUniform.depth(zoom: zoom) == 0
    }
}

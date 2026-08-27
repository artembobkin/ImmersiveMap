// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// How deep the globe surface colours are drawn this frame; the layout mirrors
/// `GlobeSurfaceTone` in RenderUniforms.h (pinned by `GlobeSurfaceToneUniformTests`).
///
/// Seen whole from space the planet wears richer, darker colours than the map
/// it becomes up close: the pale tile palette that reads well under labels at
/// a city zoom looks washed out on a small sphere against black. `depth` is 1
/// up to zoom 1, while the whole planet is on screen, and eases back to 0
/// between zoom 1 and 2, together with the terminator fade, so the surface
/// arrives at the map's own palette before the sphere starts to unfurl. The
/// shader mutes and cools the colour, deepens the midtones and rounds the lit
/// disc off toward the limb by this amount; at 0 the sampled colour passes
/// through untouched.
struct GlobeSurfaceToneUniform {
    var depth: Float
    var _padding0: Float = 0
    var _padding1: Float = 0
    var _padding2: Float = 0

    /// Zoom up to which the colours are at their deepest.
    static let deepZoom: Double = 1.0

    /// Zoom at which the surface is back to the untouched tile palette.
    static let plainZoom: Double = 2.0

    /// The tile palette as baked: what every frame past `plainZoom` draws.
    static let plain = GlobeSurfaceToneUniform(depth: 0)

    static func make(zoom: Double) -> GlobeSurfaceToneUniform {
        GlobeSurfaceToneUniform(depth: depth(zoom: zoom))
    }

    /// Deepening amount by zoom: 1 at `deepZoom` and below, 0 at `plainZoom`
    /// and above, a smoothstep between so neither end of the ramp shows a kink
    /// while the camera zooms through it.
    static func depth(zoom: Double) -> Float {
        let start = deepZoom
        let end = plainZoom
        guard zoom.isFinite, end > start else {
            return zoom <= start ? 1 : 0
        }
        let t = min(max((zoom - start) / (end - start), 0), 1)
        return Float(1 - t * t * (3 - 2 * t))
    }
}

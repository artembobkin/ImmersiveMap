// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The shading of the ground's slopes this frame (`ImmersiveMapHillshade`):
/// the scene's light, the share of the style's intensity the relief's rise
/// leaves, the style's colours, and how it fades with the distance from
/// the eye, as the fills' fragment stages read them (`GroundReliefUniform`,
/// `groundReliefHillshade` in GroundRelief.h). Resolved once a frame
/// (`GroundReliefFrameState.setLight`), so every draw on the relief shades
/// by the same light.
struct GroundReliefHillshade: Equatable {
    /// The direction toward the light in the flat basis (+X east, +Y north,
    /// +Z up), unit length, and the amount of shading, the style's
    /// intensity times how far the relief has risen: zero draws none.
    let light: SIMD4<Float>
    let shadowColor: SIMD4<Float>
    let highlightColor: SIMD4<Float>
    /// The eye in the world, where the fade is measured from.
    let eye: SIMD4<Float>
    /// The world distance from the eye the fade starts at, and one over
    /// the world distance it takes to fade out.
    let fade: SIMD4<Float>

    static let none = GroundReliefHillshade(light: SIMD4<Float>(0, 0, 1, 0),
                                            shadowColor: .zero,
                                            highlightColor: .zero,
                                            eye: .zero,
                                            fade: .zero)

    /// How much the slopes are shaded, the three amounts of a style
    /// (`ImmersiveMapHillshade`) the debug panel drags live: the
    /// intensity, and how far a slope goes toward the shadow colour and
    /// toward the highlight colour (the colours' alphas). Each 0 to 1.
    struct Amounts: Equatable {
        var intensity: Float
        var shadow: Float
        var highlight: Float

        init(intensity: Float, shadow: Float, highlight: Float) {
            self.intensity = min(max(intensity, 0), 1)
            self.shadow = min(max(shadow, 0), 1)
            self.highlight = min(max(highlight, 0), 1)
        }

        /// The amounts a style shades by.
        init(style: ImmersiveMapHillshade) {
            self.init(intensity: style.intensity, shadow: style.shadowColor.w, highlight: style.highlightColor.w)
        }

        /// The style with these amounts in place of its own.
        func applied(to style: ImmersiveMapHillshade) -> ImmersiveMapHillshade {
            var adjusted = style
            adjusted.intensity = intensity
            adjusted.shadowColor.w = shadow
            adjusted.highlightColor.w = highlight
            return adjusted
        }
    }

    /// Where the shading fades, the two curves of a style
    /// (`ImmersiveMapHillshade.fadeStartMeters`, `fadeEndMeters`) the debug
    /// panel drags live: metres from the eye by the camera zoom.
    struct Fade: Equatable {
        var startMeters: ImmersiveMapZoomCurve
        var endMeters: ImmersiveMapZoomCurve

        init(startMeters: ImmersiveMapZoomCurve, endMeters: ImmersiveMapZoomCurve) {
            self.startMeters = startMeters
            self.endMeters = endMeters
        }

        /// The fade a style shades with.
        init(style: ImmersiveMapHillshade) {
            self.init(startMeters: style.fadeStartMeters, endMeters: style.fadeEndMeters)
        }

        /// The style with this fade in place of its own.
        func applied(to style: ImmersiveMapHillshade) -> ImmersiveMapHillshade {
            var adjusted = style
            adjusted.fadeStartMeters = startMeters
            adjusted.fadeEndMeters = endMeters
            return adjusted
        }
    }

    /// The shading of a style under a light (`SceneLightSettings.direction`,
    /// toward the light) with the relief risen by `risenShare`, 0 to 1,
    /// seen from `cameraEye`, the world's origin being the point it looks
    /// at, at the camera `zoom` the fade's curves are read at and
    /// `unitsPerMetre` world units a metre. `fade` replaces the style's
    /// fade and `amounts` its amounts (the debug panel's). A light at or
    /// under the horizon shades nothing: the level ground would be lit as
    /// edgewise as the steepest slope.
    static func resolve(style: ImmersiveMapHillshade,
                        lightDirection: SIMD3<Float>,
                        risenShare: Float,
                        cameraEye: SIMD3<Float>,
                        zoom: Double,
                        unitsPerMetre: Float,
                        fade: Fade? = nil,
                        amounts: Amounts? = nil) -> GroundReliefHillshade {
        guard simd_length_squared(lightDirection) > 1e-12 else { return .none }
        var style = amounts?.applied(to: style) ?? style
        style = fade?.applied(to: style) ?? style
        let light = simd_normalize(lightDirection)
        let amount = max(0, style.intensity) * min(max(risenShare, 0), 1)
        guard light.z > minimumLightZ, amount > 0, light.x.isFinite, light.y.isFinite, light.z.isFinite,
              unitsPerMetre.isFinite, unitsPerMetre > 0 else {
            return .none
        }
        // The fade in metres at this zoom, geometric between the stops as
        // a length on the ground runs, then in the world.
        let startMetres = max(0, style.fadeStartMeters.value(atZoom: zoom, interpolation: .geometric))
        let endMetres = max(startMetres, style.fadeEndMeters.value(atZoom: zoom, interpolation: .geometric))
        let startWorld = startMetres * unitsPerMetre
        let spanWorld = max((endMetres - startMetres) * unitsPerMetre, max(startWorld, unitsPerMetre) * 1e-3)
        return GroundReliefHillshade(light: SIMD4<Float>(light, amount),
                                     shadowColor: style.shadowColor,
                                     highlightColor: style.highlightColor,
                                     eye: SIMD4<Float>(cameraEye, 0),
                                     fade: SIMD4<Float>(startWorld, 1 / spanWorld, 0, 0))
    }

    /// The lowest light the slopes are shaded by, the sine of its
    /// elevation: about half a degree over the horizon.
    static let minimumLightZ: Float = 0.01
}

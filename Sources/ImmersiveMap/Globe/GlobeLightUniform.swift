// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The sun on the globe (`ImmersiveMapSettings.GlobeLightSettings`) as the
/// shaders read it (GlobeLight.h): the sun over the subsolar point turned
/// into the world with the globe (`sunWorldDirection`), the one the
/// atmosphere's halo reads too, the strength at the frame's camera zoom and
/// through the globe's morph into the plane, the night colour and the
/// terminator's softness. The feature owns the light's settings and its
/// math and draws nothing of its own: the globe's surface draws (the tiles,
/// the raster rings, the polar caps) bind it at `bufferIndex` and their
/// fragment shaders shade through `globeLitColor`. On the plane and with
/// the light off the strength is zero and the shaders leave every colour.
struct GlobeLightUniform {
    /// Mirror of `kGlobeLightBufferIndex` in GlobeLight.h.
    static let bufferIndex = 9

    var lightAndStrength: SIMD4<Float>
    var nightColorAndSoftness: SIMD4<Float>

    static let disabled = GlobeLightUniform(lightAndStrength: SIMD4<Float>(0, 0, 1, 0),
                                            nightColorAndSoftness: .zero)

    /// The unit earth-fixed direction of a point of the planet by its
    /// geographic coordinate, in the frame the globe's vertices are
    /// projected from (`globeWorldUVUnitDirection` in GlobeTileProjection.h:
    /// y the pole axis, z toward longitude 0, x toward 90 degrees east).
    static func earthDirection(latitudeDegrees: Float, longitudeDegrees: Float) -> SIMD3<Float> {
        let latitude = latitudeDegrees * .pi / 180
        let longitude = longitudeDegrees * .pi / 180
        return SIMD3<Float>(cos(latitude) * sin(longitude), sin(latitude), cos(latitude) * cos(longitude))
    }

    /// The direction toward the sun in world space this frame: the sun
    /// over the subsolar point, turned with the globe by its pan, the
    /// turn the globe's vertices take (`GlobeFrameConstantsUniform
    /// .sphereWorld`), so the terminator lies on one part of the planet
    /// whichever way it is turned. Unit length.
    static func sunWorldDirection(settings: ImmersiveMapSettings.GlobeLightSettings,
                                  globe: GlobeUniform) -> SIMD3<Float> {
        let earth = earthDirection(latitudeDegrees: settings.subsolarLatitudeDegrees,
                                   longitudeDegrees: settings.subsolarLongitudeDegrees)
        let rotation = GlobeFrameConstantsUniform.rotationMatrix(
            panLatitude: globe.panY * Float(ImmersiveMapProjection.maxMercatorLatitude),
            panLongitude: globe.panX * Float.pi)
        let world = simd_transpose(rotation) * SIMD4<Float>(earth, 0)
        return simd_normalize(SIMD3<Float>(world.x, world.y, world.z))
    }

    /// The light fades out over the first stretch of the transition and is
    /// gone by here: the terminator is the sphere's, and the unrolling
    /// surface is no sphere.
    static let morphFadeOutEnd: Float = 0.12

    /// How much of the light is left: 1 on the resting globe, 0 from
    /// `morphFadeOutEnd` of the transition on and on the plane.
    static func morphFade(transition: Float, renderSurfaceMode: ViewMode) -> Float {
        guard renderSurfaceMode == .spherical else { return 0 }
        let t = simd_clamp(transition / morphFadeOutEnd, 0, 1)
        return 1 - t * t * (3 - 2 * t)
    }

    /// The light a frame shades the globe with: `sunWorldDirection` for
    /// the frame's globe, the strength's curve read at the camera zoom,
    /// faded out as the morph into the plane starts (`morphFade`), so the
    /// unrolling map is unshaded whatever the curve says.
    static func resolve(settings: ImmersiveMapSettings.GlobeLightSettings,
                        lightDirection: SIMD3<Float>,
                        renderSurfaceMode: ViewMode,
                        transition: Float,
                        zoom: Double) -> GlobeLightUniform {
        let morphFade = morphFade(transition: transition, renderSurfaceMode: renderSurfaceMode)
        let strength = min(max(settings.strength.value(atZoom: zoom), 0), 1) * morphFade
        guard settings.isEnabled,
              strength > 0,
              simd_length_squared(lightDirection) > 1e-12 else {
            return .disabled
        }
        let light = simd_normalize(lightDirection)
        let night = simd_clamp(settings.nightColor, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        return GlobeLightUniform(lightAndStrength: SIMD4<Float>(light, strength),
                                 nightColorAndSoftness: SIMD4<Float>(night, min(max(settings.terminatorSoftness, 0.001), 1)))
    }

    static func resolve(frameContext: FrameContext) -> GlobeLightUniform {
        let settings = frameContext.services.settings.scene.globeLight
        return resolve(settings: settings,
                lightDirection: sunWorldDirection(settings: settings, globe: frameContext.globeRenderUniform),
                renderSurfaceMode: frameContext.renderSurfaceMode,
                transition: frameContext.transition,
                // As the sky does: the globe's light follows the zoom the
                // eye sees.
                zoom: frameContext.animatedZoom)
    }

    /// Binds the light for every lit globe fragment shader the encoder
    /// draws with next.
    static func bind(_ uniform: GlobeLightUniform, encoder: MTLRenderCommandEncoder) {
        var value = uniform
        encoder.setFragmentBytes(&value, length: MemoryLayout<GlobeLightUniform>.stride, index: bufferIndex)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The fog on the ground of the flat map (`ImmersiveMapSettings
/// .GroundFogSettings`) as the shaders read it (GroundFog.h), its zoom
/// curves resolved at the frame's camera zoom. The feature owns the fog's
/// settings and its math. It draws nothing of its own: every subsystem
/// that draws something standing on the map binds this uniform at
/// `bufferIndex` and its fragment shader mixes its colour toward the
/// fog's (`applyGroundFog`). The globe has no fog: there and with the fog
/// off the uniform's strength is zero and the shaders leave every colour.
struct GroundFogUniform {
    /// Mirror of `kGroundFogBufferIndex` in GroundFog.h.
    static let bufferIndex = 12

    /// The share of the presentation's transition span, in zoom, the fog
    /// comes in over past the zoom the globe's morph ends at. The sphere's
    /// shaders draw no fog, so the plane's first frame would otherwise show
    /// it at once. A tenth of the span is the stretch the horizon's sky
    /// fades in over before the switch (`HorizonFrameResolver
    /// .fogFadeInStart`), so the sky arrives and the fog follows at the
    /// same pace.
    static let morphFadeSpanShare: Double = 0.1

    var colorAndDensity: SIMD4<Float>
    /// The eye in render world units and the meters one unit spans.
    var eyeAndMetersPerUnit: SIMD4<Float>
    /// The height and the start distance in meters, the most it veils, the
    /// strength.
    var parameters: SIMD4<Float>
    /// The sky's colour away from the line and the e-fold of the horizon's
    /// glow in radians, 0 where no sky is painted.
    var skyColorAndGradient: SIMD4<Float>
    /// The start's softness in meters in x, the rest padding.
    var startSoftness: SIMD4<Float>

    static let disabled = GroundFogUniform(colorAndDensity: .zero,
                                           eyeAndMetersPerUnit: SIMD4<Float>(0, 0, 1, 1),
                                           parameters: SIMD4<Float>(1, 0, 0, 0),
                                           skyColorAndGradient: .zero,
                                           startSoftness: .zero)

    /// The fog a frame draws with, every zoom curve read at the camera
    /// zoom, the lengths and the density geometrically between their stops
    /// (`ImmersiveMapZoomCurve.Interpolation.geometric`), so they follow the
    /// map's scale from one stop to the next. Every length is in meters,
    /// and `worldUnitsPerMeter` turns the render world into them. Only the
    /// plane is fogged: the sphere's shaders draw none of it, and on a map
    /// with the globe the fog comes in over `morphFadeSpanShare` of the
    /// transition span past the zoom the morph ends at (`morphFade`).
    static func resolve(settings: ImmersiveMapSettings,
                        renderSurfaceMode: ViewMode,
                        cameraEye: SIMD3<Float>,
                        worldUnitsPerMeter: Double,
                        zoom: Double) -> GroundFogUniform {
        let fog = settings.scene.groundFog
        let strength = morphFade(presentation: settings.presentation, zoom: zoom)
        let maximumOpacity = min(max(fog.maximumOpacity.value(atZoom: zoom), 0), 1)
        guard fog.isEnabled,
              renderSurfaceMode == .flat,
              strength > 0,
              maximumOpacity > 0,
              worldUnitsPerMeter > 0,
              worldUnitsPerMeter.isFinite else {
            return .disabled
        }
        func length(_ curve: ImmersiveMapZoomCurve) -> Float {
            max(curve.value(atZoom: zoom, interpolation: .geometric), 0)
        }
        let sky = settings.scene.fog
        let color = fog.color ?? sky.horizonColor
        // The fog takes the sky's colour above the line where the horizon
        // paints a sky. With the sky off the plane's clear colour is behind,
        // and the fog keeps its own.
        let skyGradient = sky.isEnabled ? HorizonFrameResolver.skyGradientRadians : 0
        // The settings state the density per kilometer, the shader per meter.
        let densityPerMeter = length(fog.densityPerKilometer) / 1000
        return GroundFogUniform(colorAndDensity: SIMD4<Float>(color, densityPerMeter),
                                eyeAndMetersPerUnit: SIMD4<Float>(cameraEye, Float(1 / worldUnitsPerMeter)),
                                parameters: SIMD4<Float>(max(length(fog.heightMeters), 1e-3),
                                                         length(fog.startDistanceMeters),
                                                         maximumOpacity,
                                                         strength),
                                skyColorAndGradient: SIMD4<Float>(sky.skyColor, skyGradient),
                                startSoftness: SIMD4<Float>(length(fog.startSoftnessMeters), 0, 0, 0))
    }

    /// CPU mirror of the shader's `groundFogColor`: the fog's colour in a
    /// direction `elevation` radians above the horizon line.
    func color(elevation: Float) -> SIMD3<Float> {
        let base = SIMD3<Float>(colorAndDensity.x, colorAndDensity.y, colorAndDensity.z)
        let gradient = skyColorAndGradient.w
        guard gradient > 0, elevation > 0 else { return base }
        let sky = SIMD3<Float>(skyColorAndGradient.x, skyColorAndGradient.y, skyColorAndGradient.z)
        return base + (sky - base) * (1 - exp(-elevation / gradient))
    }

    /// The fog the buildings and the models draw with: the frame's, or none
    /// where they stand clear of it (`GroundFogSettings.veilsBuildings`).
    static func resolveForBuildings(frameContext: FrameContext) -> GroundFogUniform {
        guard frameContext.services.settings.scene.groundFog.veilsBuildings else {
            return .disabled
        }
        return resolve(frameContext: frameContext)
    }

    static func resolve(frameContext: FrameContext) -> GroundFogUniform {
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: frameContext.mapCameraState.centerWorldMercator.y)
        let unitsPerMeter = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitude,
                                                                      renderMapSize: frameContext.flatRenderState.renderMapSize)
        return resolve(settings: frameContext.services.settings,
                       renderSurfaceMode: frameContext.renderSurfaceMode,
                       cameraEye: frameContext.cameraEye,
                       worldUnitsPerMeter: unitsPerMeter,
                       zoom: frameContext.zoom)
    }

    /// How much of the fog is in at a camera zoom, by the globe's morph: 1
    /// on a map without the globe, else a smoothstep from 0 at the zoom
    /// the morph ends at to 1 a `morphFadeSpanShare` of its span on.
    static func morphFade(presentation: ImmersiveMapSettings.PresentationSettings, zoom: Double) -> Float {
        guard presentation.isGlobeEnabled else { return 1 }
        let span = max(presentation.automaticTransitionSpan, 0)
        let planeZoom = presentation.automaticTransitionStartZoom + span
        let width = max(span * morphFadeSpanShare, 1e-6)
        let t = simd_clamp(Float((zoom - planeZoom) / width), 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// Binds the fog for every fogged fragment shader the encoder draws
    /// with next.
    static func bind(_ uniform: GroundFogUniform, encoder: MTLRenderCommandEncoder) {
        var value = uniform
        encoder.setFragmentBytes(&value, length: MemoryLayout<GroundFogUniform>.stride, index: bufferIndex)
    }
}

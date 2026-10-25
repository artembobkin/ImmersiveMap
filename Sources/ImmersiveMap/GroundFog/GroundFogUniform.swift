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
    /// it at once. A tenth of the span is about the stretch the horizon's
    /// sky fades in over before the switch (the air handover,
    /// `PresentationSettings.airHandoverStart` to `airHandoverEnd`), so
    /// the sky arrives and the fog follows at the same pace.
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
    /// The start's softness in meters in x, the altitude of the plane the
    /// ground is drawn from in y (the terrain under the point the camera
    /// looks at, in meters, 0 off the relief or with the heights from the
    /// plane) and the altitude the density is stated at in z, the rest
    /// padding.
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
    /// `datumMetres` is the altitude of the plane the ground is drawn from
    /// on the relief (`GroundReliefFrame.datumMetres`): with
    /// `GroundFogSettings.heightsFromSeaLevel` the fog's heights are the
    /// ground's own altitudes, the plane's plus it.
    ///
    /// With an air over the mountains set (`SceneSettings.mountainGroundFog`)
    /// the frame draws the air `mountainousness` of the way from the plain's
    /// to it (`ImmersiveMapTerrainSurroundings.mountainousness`): both are
    /// read at the zoom and mixed number by number (`Air`), the switches
    /// among them as shares, so a pan from a plain into a range fades one
    /// air into the other and an air switched off fades the fog out.
    /// `forBuildings` asks for the fog the buildings and the models draw
    /// with: the frame's, at the share of it that veils them
    /// (`GroundFogSettings.veilsBuildings`).
    static func resolve(settings: ImmersiveMapSettings,
                        renderSurfaceMode: ViewMode,
                        cameraEye: SIMD3<Float>,
                        worldUnitsPerMeter: Double,
                        zoom: Double,
                        onGroundRelief: Bool = false,
                        datumMetres: Float = 0,
                        mountainousness: Float = 0,
                        forBuildings: Bool = false) -> GroundFogUniform {
        let sky = settings.scene.fog
        var air = Air(fog: settings.scene.groundFog, sky: sky, zoom: zoom, onGroundRelief: onGroundRelief)
        if let mountainFog = settings.scene.mountainGroundFog, mountainousness > 0 {
            air = Air.mix(air, Air(fog: mountainFog, sky: sky, zoom: zoom, onGroundRelief: onGroundRelief),
                          min(mountainousness, 1))
        }
        var strength = morphFade(presentation: settings.presentation, zoom: zoom) * air.isOn
        if forBuildings {
            strength *= air.veilsBuildings
        }
        let maximumOpacity = min(max(air.maximumOpacity, 0), 1)
        guard renderSurfaceMode == .flat,
              strength > 0,
              maximumOpacity > 0,
              worldUnitsPerMeter > 0,
              worldUnitsPerMeter.isFinite else {
            return .disabled
        }
        return GroundFogUniform(colorAndDensity: SIMD4<Float>(air.color, air.densityPerMeter),
                                eyeAndMetersPerUnit: SIMD4<Float>(cameraEye, Float(1 / worldUnitsPerMeter)),
                                parameters: SIMD4<Float>(max(air.heightMeters, 1e-3),
                                                         air.startDistanceMeters,
                                                         maximumOpacity,
                                                         strength),
                                skyColorAndGradient: SIMD4<Float>(sky.skyColor, air.skyGradient),
                                startSoftness: SIMD4<Float>(air.startSoftnessMeters,
                                                            air.datumShare * datumMetres,
                                                            air.baseAltitudeMeters,
                                                            0))
    }

    /// One air at a zoom, as numbers: every curve read there and every
    /// switch a share, 0 or 1, so two airs mix (`mix`) into one that the
    /// uniform is built from.
    struct Air {
        /// 1 with the fog on, 0 off.
        var isOn: Float
        var densityPerMeter: Float
        var heightMeters: Float
        var startDistanceMeters: Float
        var startSoftnessMeters: Float
        var maximumOpacity: Float
        var color: SIMD3<Float>
        /// The e-fold of the horizon's glow where the fog takes the sky's
        /// colour, 0 where it keeps its own.
        var skyGradient: Float
        /// 1 with the heights from sea level, the datum's share.
        var datumShare: Float
        /// The altitude the density is stated at, 0 with the heights from
        /// the plane.
        var baseAltitudeMeters: Float
        /// 1 where the fog veils the buildings and the models.
        var veilsBuildings: Float

        /// The air's values at `zoom`, the lengths and the density read
        /// geometrically between their stops
        /// (`ImmersiveMapZoomCurve.Interpolation.geometric`), so they follow
        /// the map's scale from one stop to the next. The colour is the
        /// fog's own or the horizon's. Asked to, the fog takes the sky's
        /// colour above the line where the horizon paints a sky. With the
        /// sky off the plane's clear colour is behind, and the fog keeps its
        /// own. On the ground relief it keeps its own everywhere: the line
        /// is the plane's, not the terrain's, and a hill crossing it would
        /// turn from the fog's colour to the sky's along that line, a seam
        /// across the hill.
        init(fog: ImmersiveMapSettings.GroundFogSettings,
             sky: ImmersiveMapSettings.FogSettings,
             zoom: Double,
             onGroundRelief: Bool) {
            func length(_ curve: ImmersiveMapZoomCurve) -> Float {
                max(curve.value(atZoom: zoom, interpolation: .geometric), 0)
            }
            isOn = fog.isEnabled ? 1 : 0
            // The settings state the density per kilometer, the shader per meter.
            densityPerMeter = length(fog.densityPerKilometer) / 1000
            heightMeters = length(fog.heightMeters)
            startDistanceMeters = length(fog.startDistanceMeters)
            startSoftnessMeters = length(fog.startSoftnessMeters)
            maximumOpacity = fog.maximumOpacity.value(atZoom: zoom)
            color = fog.color ?? sky.horizonColor
            let takesSky = fog.takesSkyColor && sky.isEnabled && onGroundRelief == false
            skyGradient = takesSky ? HorizonFrameResolver.skyGradientRadians : 0
            datumShare = fog.heightsFromSeaLevel ? 1 : 0
            baseAltitudeMeters = fog.heightsFromSeaLevel ? fog.baseAltitudeMeters : 0
            veilsBuildings = fog.veilsBuildings ? 1 : 0
        }

        /// The air `share` of the way from `a` to `b`, every number alike.
        static func mix(_ a: Air, _ b: Air, _ share: Float) -> Air {
            let t = min(max(share, 0), 1)
            func blend(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
            var air = a
            air.isOn = blend(a.isOn, b.isOn)
            air.densityPerMeter = blend(a.densityPerMeter, b.densityPerMeter)
            air.heightMeters = blend(a.heightMeters, b.heightMeters)
            air.startDistanceMeters = blend(a.startDistanceMeters, b.startDistanceMeters)
            air.startSoftnessMeters = blend(a.startSoftnessMeters, b.startSoftnessMeters)
            air.maximumOpacity = blend(a.maximumOpacity, b.maximumOpacity)
            air.color = a.color + (b.color - a.color) * t
            air.skyGradient = blend(a.skyGradient, b.skyGradient)
            air.datumShare = blend(a.datumShare, b.datumShare)
            air.baseAltitudeMeters = blend(a.baseAltitudeMeters, b.baseAltitudeMeters)
            air.veilsBuildings = blend(a.veilsBuildings, b.veilsBuildings)
            return air
        }
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
        resolve(frameContext: frameContext, forBuildings: true)
    }

    static func resolve(frameContext: FrameContext, forBuildings: Bool = false) -> GroundFogUniform {
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: frameContext.mapCameraState.centerWorldMercator.y)
        let unitsPerMeter = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitude,
                                                                      renderMapSize: frameContext.flatRenderState.renderMapSize)
        return resolve(settings: frameContext.services.settings,
                       renderSurfaceMode: frameContext.renderSurfaceMode,
                       cameraEye: frameContext.cameraEye,
                       worldUnitsPerMeter: unitsPerMeter,
                       // The air reads the planning zoom: over the terrain the
                       // camera's own zoom follows the ground under the point
                       // it looks at, a summit or a valley floor, and the air
                       // is the same air whichever the camera settles on.
                       zoom: frameContext.planningZoom,
                       onGroundRelief: frameContext.services.groundRelief?.isActive ?? false,
                       // The plane's altitude: the ground rises from the
                       // terrain under the point the camera looks at.
                       datumMetres: (frameContext.services.groundRelief?.isActive ?? false)
                           ? (frameContext.services.groundRelief?.datumMetres ?? 0)
                           : 0,
                       // How mountainous the country around the camera reads,
                       // nil off the terrain: the plain's air then.
                       mountainousness: frameContext.terrainSurroundings?.mountainousness ?? 0,
                       forBuildings: forBuildings)
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

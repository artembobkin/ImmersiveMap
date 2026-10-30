// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap
import simd

/// What the debug panel has been dragged to, kept apart from the settings the
/// app supplies.
///
/// SwiftUI calls `updateNSView` on every re-evaluation of the hierarchy and
/// hands the map the app's own settings value again. Without this, a slider in
/// the panel reverted the moment anything else on screen changed, so dragging
/// one felt like it did nothing at all. The panel's values ride on top of every
/// incoming settings value instead, and a drag holds until it is dragged
/// somewhere else.
///
/// The override is scoped to the debug panel being on: turning it off drops
/// the values, and the app's own settings come straight back.
struct DebugOverlaySettingsOverride: Equatable {
    var shadows: ImmersiveMapSettings.ShadowSettings?
    var sunDirection: SIMD3<Float>?
    var fog: ImmersiveMapSettings.FogSettings?
    var atmosphere: ImmersiveMapSettings.AtmosphereSettings?
    var globeLight: ImmersiveMapSettings.GlobeLightSettings?
    var groundFog: ImmersiveMapSettings.GroundFogSettings?
    /// The air over the mountains, itself optional: `.some(nil)` is the
    /// panel having switched it off, nil no drag.
    var mountainGroundFog: ImmersiveMapSettings.GroundFogSettings??
    var terrainSurroundings: ImmersiveMapSettings.TileSettings.TerrainSurroundingsSettings?
    /// The models' depth bias, for a map with a model archive.
    var modelDepthBias: ImmersiveMapZoomCurve?

    var isEmpty: Bool {
        shadows == nil && sunDirection == nil && fog == nil && atmosphere == nil && globeLight == nil && groundFog == nil
            && mountainGroundFog == nil && terrainSurroundings == nil && modelDepthBias == nil
    }

    mutating func clear() {
        shadows = nil
        sunDirection = nil
        fog = nil
        atmosphere = nil
        globeLight = nil
        groundFog = nil
        mountainGroundFog = nil
        terrainSurroundings = nil
        modelDepthBias = nil
    }

    func applied(to settings: ImmersiveMapSettings) -> ImmersiveMapSettings {
        guard settings.debug.enableDebugPanel, isEmpty == false else {
            return settings
        }

        var overridden = settings
        if let shadows {
            overridden.scene.shadows = shadows
        }
        if let sunDirection {
            overridden.scene.light.direction = sunDirection
        }
        if let fog {
            overridden.scene.fog = fog
        }
        if let atmosphere {
            overridden.scene.atmosphere = atmosphere
        }
        if let globeLight {
            overridden.scene.globeLight = globeLight
        }
        if let groundFog {
            overridden.scene.groundFog = groundFog
        }
        if let mountainGroundFog {
            overridden.scene.mountainGroundFog = mountainGroundFog
        }
        if let terrainSurroundings {
            overridden.tiles.groundRelief.surroundings = terrainSurroundings
        }
        if let modelDepthBias {
            overridden.modelArchive?.depthBias = modelDepthBias
        }
        return overridden
    }
}

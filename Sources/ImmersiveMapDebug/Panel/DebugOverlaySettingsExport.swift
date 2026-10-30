// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap
import Foundation

/// What the debug panel's Export tab writes: the values the panel tunes,
/// as the `ImmersiveMapView` modifiers that set them, so a look found by
/// hand is pasted into an app as it is. The sky, the ground fog with its
/// zoom curves and the air over the mountains, the light and the shadows,
/// the globe's atmosphere, and how the country around the camera is read
/// as mountains or a plain.
///
/// Only those. The rest of `ImmersiveMapSettings` holds the tile archive's
/// address and request headers, where an access token lives, and a file
/// made to be passed around must not carry one.
enum DebugOverlaySettingsExport {
    /// The file's text: a header naming when and where it was taken, then
    /// the modifiers, one per line.
    static func swiftCode(settings: ImmersiveMapSettings, date: Date, cameraLines: [String]) -> String {
        let scene = settings.scene
        var lines = ["// ImmersiveMap settings exported from the debug panel",
                     "// \(ISO8601DateFormatter().string(from: date))"]
        lines += cameraLines.map { "// \($0)" }
        lines += ["", "ImmersiveMapView()"]
        lines += modifiers(scene, surroundings: settings.tiles.groundRelief.surroundings).map { "    \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The file's name: sortable by when it was taken.
    static func fileName(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "ImmersiveMapSettings-\(formatter.string(from: date)).swift"
    }

    static func modifiers(_ scene: ImmersiveMapSettings.SceneSettings,
                          surroundings: ImmersiveMapSettings.TileSettings.TerrainSurroundingsSettings) -> [String] {
        let fog = scene.fog
        let shadows = scene.shadows
        let atmosphere = scene.atmosphere
        let globeLight = scene.globeLight
        var lines = [
            ".fogSettings(ImmersiveMapSettings.FogSettings(isEnabled: \(fog.isEnabled), "
                + "skyColor: \(vector(fog.skyColor)), "
                + "horizonColor: \(vector(fog.horizonColor))))",
            ".groundFog(\(groundFogArguments(scene.groundFog).joined(separator: ", ")))"
        ]
        if let mountainGroundFog = scene.mountainGroundFog {
            lines.append(".mountainGroundFog(\(groundFogArguments(mountainGroundFog).joined(separator: ", ")))")
        }
        return lines + [
            ".sceneLight(direction: \(vector(scene.light.direction)))",
            ".shadows(isEnabled: \(shadows.isEnabled), "
                + "strength: \(curve(shadows.strength)), "
                + "mapResolution: \(shadows.mapResolution), "
                + "nearCoverageMeters: \(curve(shadows.nearCoverageMeters)), "
                + "farCoverageMeters: \(curve(shadows.farCoverageMeters)), "
                + "maxCasterHeightMeters: \(number(shadows.maxCasterHeightMeters)), "
                + "normalOffsetTexels: \(number(shadows.normalOffsetTexels)), "
                + "softness: \(number(shadows.softness)), "
                + "tint: \(vector(shadows.tint)))",
            ".atmosphereSettings(ImmersiveMapSettings.AtmosphereSettings(isEnabled: \(atmosphere.isEnabled), "
                + "color: \(vector(atmosphere.color)), "
                + "intensity: \(number(atmosphere.intensity)), "
                + "thickness: \(curve(atmosphere.thickness)), "
                + "sunInfluence: \(number(atmosphere.sunInfluence))))",
            ".globeLight(isEnabled: \(globeLight.isEnabled), "
                + "subsolarLatitudeDegrees: \(number(globeLight.subsolarLatitudeDegrees)), "
                + "subsolarLongitudeDegrees: \(number(globeLight.subsolarLongitudeDegrees)), "
                + "strength: \(curve(globeLight.strength)), "
                + "terminatorSoftness: \(number(globeLight.terminatorSoftness)), "
                + "nightColor: \(vector(globeLight.nightColor)))",
            ".terrainSurroundings(sampleRadiusMetres: \(number(surroundings.sampleRadiusMetres)), "
                + "plainBelowMetres: \(number(surroundings.plainBelowMetres)), "
                + "mountainsAboveMetres: \(number(surroundings.mountainsAboveMetres)), "
                + "smoothingHalfLife: \(number(Float(surroundings.smoothingHalfLife))))"
        ]
    }

    /// An air's values as the arguments of `groundFog(...)` and
    /// `mountainGroundFog(...)`, which take the same.
    static func groundFogArguments(_ groundFog: ImmersiveMapSettings.GroundFogSettings) -> [String] {
        var arguments = ["isEnabled: \(groundFog.isEnabled)",
                         "densityPerKilometer: \(curve(groundFog.densityPerKilometer))",
                         "heightMeters: \(curve(groundFog.heightMeters))",
                         "startDistanceMeters: \(curve(groundFog.startDistanceMeters))",
                         "startSoftnessMeters: \(curve(groundFog.startSoftnessMeters))"]
        if let color = groundFog.color {
            arguments.append("color: \(vector(color))")
        }
        arguments.append("maximumOpacity: \(curve(groundFog.maximumOpacity))")
        arguments.append("veilsBuildings: \(groundFog.veilsBuildings)")
        arguments.append("takesSkyColor: \(groundFog.takesSkyColor)")
        arguments.append("heightsFromSeaLevel: \(groundFog.heightsFromSeaLevel)")
        arguments.append("baseAltitudeMeters: \(number(groundFog.baseAltitudeMeters))")
        return arguments
    }

    /// A curve as the literal that writes it: one value, or its stops.
    static func curve(_ curve: ImmersiveMapZoomCurve) -> String {
        if let value = curve.constantValue {
            return number(value)
        }
        let stops = curve.stops.map { "\(zoom($0.zoom)): \(number($0.value))" }
        return "[\(stops.joined(separator: ", "))]"
    }

    static func zoomFade(_ fade: ImmersiveMapZoomFade) -> String {
        if fade == .none {
            return ".none"
        }
        if fade.zeroAlphaZoom < fade.fullAlphaZoom {
            return ".fadeIn(from: \(zoom(fade.zeroAlphaZoom)), to: \(zoom(fade.fullAlphaZoom)))"
        }
        return ".fadeOut(from: \(zoom(fade.fullAlphaZoom)), to: \(zoom(fade.zeroAlphaZoom)))"
    }

    /// A value with as many decimals as it has, up to four: a hand-tuned
    /// 0.3 reads 0.3, not 0.30000001.
    static func number(_ value: Float) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    private static func zoom(_ value: Double) -> String {
        number(Float(value))
    }

    private static func vector(_ value: SIMD3<Float>) -> String {
        "SIMD3<Float>(\(number(value.x)), \(number(value.y)), \(number(value.z)))"
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The ground fog group's graph axes and titles, kept out of the AppKit view
/// so they can be tested without a window. The panel edits
/// `ImmersiveMapSettings.GroundFogSettings` live.
///
/// Every value of the fog but the colour is a curve over the zoom, edited
/// on a graph of its own (`DebugOverlayZoomCurveView`): the zoom across,
/// the value up. A title carries the value at the camera's zoom, which the
/// graph marks with a line. The lengths and the density are drawn in
/// decades and run geometrically between their stops, as the fog reads
/// them, so 50 m and 20 km are both on one axis.
enum DebugOverlayGroundFogSettingsPlanner {
    /// The zooms every graph spans: the whole range a camera reaches, so a
    /// value the same at every zoom (one stop at zoom 0) is on it too.
    static let zoomRange: ClosedRange<Double> = 0...22

    /// Per kilometer at the ground: a veil at the bottom, a wall at the top.
    static let densityAxes = DebugOverlayZoomCurveAxes(zoomRange: zoomRange, valueRange: 0.001...100,
                                                       isLogarithmic: true, interpolation: .geometric)
    /// Meters: a layer at the feet of the buildings to a haze that fills
    /// the view of a camera pulled back to the plane's lowest zoom.
    static let heightAxes = DebugOverlayZoomCurveAxes(zoomRange: zoomRange, valueRange: 1...500_000,
                                                      isLogarithmic: true, interpolation: .geometric)
    /// Meters from the eye, from the street to the plane's lowest zoom.
    static let startDistanceAxes = DebugOverlayZoomCurveAxes(zoomRange: zoomRange, valueRange: 10...2_000_000,
                                                             isLogarithmic: true, interpolation: .geometric)
    /// Meters past the start.
    static let startSoftnessAxes = DebugOverlayZoomCurveAxes(zoomRange: zoomRange, valueRange: 10...10_000_000,
                                                             isLogarithmic: true, interpolation: .geometric)
    static let maximumOpacityAxes = DebugOverlayZoomCurveAxes(zoomRange: zoomRange, valueRange: 0...1)
    /// The altitude the density is stated at, meters: sea level to the
    /// high valleys.
    static let baseAltitudeRange: ClosedRange<Double> = 0...5000

    static func densityTitle(_ density: ImmersiveMapZoomCurve, cameraZoom: Double) -> String {
        "Density \(densityText(value(density, densityAxes, cameraZoom)))"
    }

    static func heightTitle(_ height: ImmersiveMapZoomCurve, cameraZoom: Double) -> String {
        "Height \(metersText(value(height, heightAxes, cameraZoom)))"
    }

    static func startDistanceTitle(_ distance: ImmersiveMapZoomCurve, cameraZoom: Double) -> String {
        "From \(metersText(value(distance, startDistanceAxes, cameraZoom)))"
    }

    static func startSoftnessTitle(_ softness: ImmersiveMapZoomCurve, cameraZoom: Double) -> String {
        "Soft start \(metersText(value(softness, startSoftnessAxes, cameraZoom)))"
    }

    static func maximumOpacityTitle(_ opacity: ImmersiveMapZoomCurve, cameraZoom: Double) -> String {
        "Max opacity \(String(format: "%.2f", value(opacity, maximumOpacityAxes, cameraZoom)))"
    }

    /// A starting point for the air over mountains, to drag from: the haze
    /// from the camera on with no clear stretch, thin (half the light gone
    /// in some 35 km), a 2.5 km layer that is thickest up to the valleys'
    /// floor at 1500 m and thins over the summits, in a cool grey-blue.
    /// The stops at zooms 7 and 12 are replaced, the street zooms' (16 and
    /// 22) kept, so the city's fog stays as the app has it.
    static func mountainAirPreset(from fog: ImmersiveMapSettings.GroundFogSettings) -> ImmersiveMapSettings.GroundFogSettings {
        var preset = fog
        preset.isEnabled = true
        preset.heightsFromSeaLevel = true
        preset.baseAltitudeMeters = 1500
        preset.color = SIMD3<Float>(0.72, 0.79, 0.88)
        preset.densityPerKilometer = replacingOverviewStops(of: fog.densityPerKilometer, with: 0.02)
        preset.heightMeters = replacingOverviewStops(of: fog.heightMeters, with: 2500)
        // Geometric curves cannot hold a zero: ten meters is no clear
        // stretch to speak of.
        preset.startDistanceMeters = replacingOverviewStops(of: fog.startDistanceMeters, with: 10)
        preset.startSoftnessMeters = replacingOverviewStops(of: fog.startSoftnessMeters, with: 3000)
        return preset
    }

    /// The zooms the overview's stops of the shipping curves sit at, the
    /// relief's zooms and below.
    static let overviewStopZooms: ClosedRange<Double> = 0...13

    /// `curve` with every stop up to zoom 13 dropped and one value put at
    /// zooms 7 and 12 in their place: the overview reads it, and the stops
    /// past it are the curve's own.
    static func replacingOverviewStops(of curve: ImmersiveMapZoomCurve, with value: Float) -> ImmersiveMapZoomCurve {
        let kept = curve.stops.filter { overviewStopZooms.contains($0.zoom) == false }
        return ImmersiveMapZoomCurve(stops: kept + [ImmersiveMapZoomCurve.Stop(zoom: 7, value: value),
                                                    ImmersiveMapZoomCurve.Stop(zoom: 12, value: value)])
    }

    static func baseAltitudeTitle(_ meters: Float) -> String {
        "Full density up to \(metersText(Double(meters)))"
    }

    /// A length as it reads best: whole meters under a kilometer,
    /// kilometers with one decimal from there.
    static func metersText(_ meters: Double) -> String {
        if meters < 1000 {
            return String(format: "%.0f m", meters)
        }
        let kilometers = String(format: "%.1f", meters / 1000)
        return "\(kilometers.hasSuffix(".0") ? String(kilometers.dropLast(2)) : kilometers) km"
    }

    static func densityText(_ density: Double) -> String {
        "\(String(format: "%g", (density * 100).rounded() / 100))/km"
    }

    private static func value(_ curve: ImmersiveMapZoomCurve,
                              _ axes: DebugOverlayZoomCurveAxes,
                              _ cameraZoom: Double) -> Double {
        Double(curve.value(atZoom: cameraZoom, interpolation: axes.interpolation))
    }
}

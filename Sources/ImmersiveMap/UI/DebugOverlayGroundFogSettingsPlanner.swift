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

    /// A starting point for the air over mountains, to drag from: the
    /// settings' own (`GroundFogSettings.mountainAir(from:)`), the default
    /// air over the mountains made of the plain's.
    static func mountainAirPreset(from fog: ImmersiveMapSettings.GroundFogSettings) -> ImmersiveMapSettings.GroundFogSettings {
        ImmersiveMapSettings.GroundFogSettings.mountainAir(from: fog)
    }

    /// The zooms the overview's stops of the shipping curves sit at, the
    /// relief's zooms and below (`GroundFogSettings.overviewStopZooms`).
    static let overviewStopZooms = ImmersiveMapSettings.GroundFogSettings.overviewStopZooms

    static func replacingOverviewStops(of curve: ImmersiveMapZoomCurve, with value: Float) -> ImmersiveMapZoomCurve {
        ImmersiveMapSettings.GroundFogSettings.replacingOverviewStops(of: curve, with: value)
    }

    static func baseAltitudeTitle(_ meters: Float) -> String {
        "Full density up to \(metersText(Double(meters)))"
    }

    /// A length as it reads best (`DebugOverlayValueText.meters`).
    static func metersText(_ meters: Double) -> String {
        DebugOverlayValueText.meters(meters)
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

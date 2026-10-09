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

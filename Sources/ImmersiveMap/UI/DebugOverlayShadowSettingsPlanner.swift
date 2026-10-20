// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The shadow group's values and their titles, kept out of the AppKit view so
/// the arithmetic can be tested without a window.
///
/// The panel edits `ImmersiveMapSettings.ShadowSettings` live, and the
/// hillshade's fade (`ImmersiveMapHillshade`) over the style's. The strength,
/// the two coverages and the fade are curves over the zoom, each edited on
/// a graph of its own (`DebugOverlayZoomCurveView`, the one the air and the
/// atmosphere edit theirs on): the zoom across, the value up, the title
/// carrying the value at the camera's zoom, which the graph marks with a
/// line. The lengths are drawn in decades and run geometrically between
/// their stops, as the resolver reads them, so 50 m and 500 km are both on
/// one axis. The slider ranges are the ones that are useful to drag
/// through, and the map size is a ladder of powers of two because those
/// are the only sizes worth comparing.
enum DebugOverlayShadowSettingsPlanner {
    static let mapResolutions = [512, 1024, 2048, 4096]
    static let mapResolutionTitles = ["512", "1K", "2K", "4K"]
    /// The zooms every graph spans: the whole range a camera reaches, so a
    /// value the same at every zoom (one stop at zoom 0) is on it too.
    static let zoomRange: ClosedRange<Double> = 0...22
    /// How dark the shadows are, 0 to 1, by the zoom: the shadows' zoom is
    /// where the curve leaves zero.
    static let strengthAxes = DebugOverlayZoomCurveAxes(zoomRange: zoomRange, valueRange: 0...1)
    /// Metres on the ground, the resolver's whole clamp
    /// (`ShadowFrameStateResolver.coverageMetersRange`): the floor is far
    /// below anything worth shipping, since winding the window right down
    /// is how the texel grid itself is looked at. Under a window of one
    /// camera distance the window's edge shows as a circle, which is
    /// expected there rather than a defect (see
    /// `ShadowFrameStateResolver.fadeDistances`).
    static var coverageAxes: DebugOverlayZoomCurveAxes {
        let range = ShadowFrameStateResolver.coverageMetersRange
        return DebugOverlayZoomCurveAxes(zoomRange: zoomRange,
                                         valueRange: Double(range.lowerBound)...Double(range.upperBound),
                                         isLogarithmic: true, interpolation: .geometric)
    }
    /// Metres from the eye the hillshade fades over, the street to the
    /// whole of a range seen from the relief's first zoom.
    static let hillshadeFadeAxes = DebugOverlayZoomCurveAxes(zoomRange: zoomRange, valueRange: 10...1_000_000,
                                                             isLogarithmic: true, interpolation: .geometric)
    /// The resolver's own clamp, so the slider can reach everything the
    /// setting accepts and nothing it does not: a slider that runs past the
    /// clamp reports a value the renderer is not using.
    /// The resolver's own clamp on the caster-height limit.
    static var casterHeightRange: ClosedRange<Double> {
        let range = ShadowFrameStateResolver.maxCasterHeightRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    static var normalOffsetRange: ClosedRange<Double> {
        let range = ShadowFrameStateResolver.normalOffsetTexelsRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    /// The resolver's own clamp on the tent's tap spread.
    static var softnessRange: ClosedRange<Double> {
        let range = ShadowFrameStateResolver.softnessRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    static let azimuthRange: ClosedRange<Double> = 0...360
    /// The resolver drops shadows below a light elevation of ~3 degrees
    /// (`minimumLightDirectionZ`), so the slider stops well above it: a slider
    /// whose bottom end silently turns the feature off reads as a bug.
    static let elevationRange: ClosedRange<Double> = 5...85

    /// Index of the ladder step at or above the current resolution, so an
    /// arbitrary value set in code still selects a segment.
    static func mapResolutionIndex(for resolution: Int) -> Int {
        if let exact = mapResolutions.firstIndex(of: resolution) {
            return exact
        }
        let nearest = mapResolutions.enumerated().min { lhs, rhs in
            abs(lhs.element - resolution) < abs(rhs.element - resolution)
        }
        return nearest?.offset ?? 0
    }

    static func mapResolution(atIndex index: Int) -> Int {
        guard mapResolutions.indices.contains(index) else {
            return mapResolutions[0]
        }
        return mapResolutions[index]
    }

    /// The strength at the camera's zoom, and that the shadows are off
    /// there when it is nothing.
    static func strengthTitle(_ strength: ImmersiveMapZoomCurve, cameraZoom: Double) -> String {
        let value = ImmersiveMapSettings.ShadowSettings(strength: strength).strength(atZoom: cameraZoom)
        return value > 0 ? String(format: "Strength %.2f", value) : "Strength 0 (off at this zoom)"
    }

    static func nearCoverageTitle(_ coverage: ImmersiveMapZoomCurve, cameraZoom: Double) -> String {
        "Near coverage \(metersText(coverageMeters(coverage, cameraZoom: cameraZoom)))"
    }

    /// The far coverage's title at the camera's zoom, or that the far
    /// window is off there because the far coverage does not reach past
    /// the near one (`ShadowFrameStateResolver.farWindowReaches`).
    static func farCoverageTitle(_ farCoverage: ImmersiveMapZoomCurve,
                                 nearCoverage: ImmersiveMapZoomCurve,
                                 cameraZoom: Double) -> String {
        let far = coverageMeters(farCoverage, cameraZoom: cameraZoom)
        let near = coverageMeters(nearCoverage, cameraZoom: cameraZoom)
        return ShadowFrameStateResolver.farWindowReaches(farRadius: far, nearRadius: near)
            ? "Far coverage \(metersText(far))"
            : "Far coverage \(metersText(far)) (off, under the near)"
    }

    static func hillshadeFadeStartTitle(_ start: ImmersiveMapZoomCurve, cameraZoom: Double) -> String {
        "Hillshade from \(metersText(start.value(atZoom: cameraZoom, interpolation: .geometric)))"
    }

    static func hillshadeFadeEndTitle(_ end: ImmersiveMapZoomCurve, cameraZoom: Double) -> String {
        "Hillshade to \(metersText(end.value(atZoom: cameraZoom, interpolation: .geometric)))"
    }

    /// A coverage at the camera's zoom as the resolver clamps it, in metres.
    static func coverageMeters(_ coverage: ImmersiveMapZoomCurve, cameraZoom: Double) -> Float {
        let range = ShadowFrameStateResolver.coverageMetersRange
        let meters = coverage.value(atZoom: cameraZoom, interpolation: .geometric)
        return meters.isFinite ? min(max(meters, range.lowerBound), range.upperBound) : range.lowerBound
    }

    static func metersText(_ meters: Float) -> String {
        DebugOverlayValueText.meters(Double(meters))
    }

    static func casterHeightTitle(_ meters: Float) -> String {
        String(format: "Caster height %.0f m", meters)
    }

    static func normalOffsetTitle(_ texels: Float) -> String {
        String(format: "Normal offset %.1ftx", texels)
    }

    static func softnessTitle(_ softness: Float) -> String {
        String(format: "Softness %.2fx", softness)
    }

    static func azimuthTitle(_ degrees: Double) -> String {
        String(format: "Sun azimuth %.0f°", degrees)
    }

    static func elevationTitle(_ degrees: Double) -> String {
        String(format: "Sun elevation %.0f°", degrees)
    }
}

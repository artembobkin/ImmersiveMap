// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// The arithmetic of the debug panel's zoom curve graph
/// (`DebugOverlayZoomCurveView`), kept out of the AppKit view so it can be
/// tested without a window: the axes (zoom across, the value up), where a
/// point of the graph lies, and the edits a pointer makes to a curve.
///
/// A stop's zoom lies on a half zoom grid and its value is rounded to a
/// hundredth, so a curve tuned by hand reads cleanly when it is copied into
/// code. Two stops never share a zoom: a curve does not jump.
struct DebugOverlayZoomCurveAxes: Equatable {
    /// The zooms across the graph.
    var zoomRange: ClosedRange<Double>
    /// The values up the graph.
    var valueRange: ClosedRange<Double>
    /// A value axis in decades rather than in equal steps, for a value that
    /// matters by its ratio (a height from a film to a wall). The range's
    /// lower bound must then be above zero.
    var isLogarithmic: Bool = false
    /// How the curve runs between its stops, as the setting it edits reads
    /// it, so the graph draws the curve the map follows.
    var interpolation: ImmersiveMapZoomCurve.Interpolation = .smooth

    /// The zoom grid a stop is placed on.
    static let zoomStep: Double = 0.5
    /// The rounding of a stop's value on an axis of equal steps. A
    /// logarithmic axis keeps two significant digits instead: 1200 m,
    /// 0.45 per kilometer.
    static let valueStep: Double = 0.01

    /// Where a zoom lies across a rectangle, left to right.
    func x(zoom: Double, in rect: CGRect) -> CGFloat {
        rect.minX + rect.width * CGFloat(fraction(zoom, of: zoomRange))
    }

    /// Where a value lies up a rectangle whose y grows downward.
    func y(value: Double, in rect: CGRect) -> CGFloat {
        rect.maxY - rect.height * CGFloat(valueFraction(value))
    }

    /// The zoom at a point across a rectangle, on the grid, inside the range.
    func zoom(x: CGFloat, in rect: CGRect) -> Double {
        let share = rect.width > 0 ? Double((x - rect.minX) / rect.width) : 0
        let zoom = zoomRange.lowerBound + share * (zoomRange.upperBound - zoomRange.lowerBound)
        let snapped = (zoom / Self.zoomStep).rounded() * Self.zoomStep
        return min(max(snapped, zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// The value at a point up a rectangle, rounded, inside the range.
    func value(y: CGFloat, in rect: CGRect) -> Double {
        let share = rect.height > 0 ? Double((rect.maxY - y) / rect.height) : 0
        let clamped = min(max(share, 0), 1)
        let value: Double
        if isLogarithmic {
            let low = log10(valueRange.lowerBound)
            let high = log10(valueRange.upperBound)
            value = pow(10, low + clamped * (high - low))
        } else {
            value = valueRange.lowerBound + clamped * (valueRange.upperBound - valueRange.lowerBound)
        }
        let rounded: Double
        if isLogarithmic, value > 0 {
            let magnitude = pow(10, floor(log10(value)) - 1)
            rounded = (value / magnitude).rounded() * magnitude
        } else {
            rounded = (value / Self.valueStep).rounded() * Self.valueStep
        }
        return min(max(rounded, valueRange.lowerBound), valueRange.upperBound)
    }

    private func valueFraction(_ value: Double) -> Double {
        guard isLogarithmic else {
            return fraction(value, of: valueRange)
        }
        let low = log10(valueRange.lowerBound)
        let high = log10(valueRange.upperBound)
        return min(max((log10(max(value, valueRange.lowerBound)) - low) / (high - low), 0), 1)
    }

    private func fraction(_ value: Double, of range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }
}

/// The edits a pointer makes to a curve on the graph.
enum DebugOverlayZoomCurveEditing {
    /// The stop under a point, if one lies within `radius` of it: the
    /// nearest, so two close stops are still told apart.
    static func stopIndex(at point: CGPoint,
                          curve: ImmersiveMapZoomCurve,
                          axes: DebugOverlayZoomCurveAxes,
                          rect: CGRect,
                          radius: CGFloat) -> Int? {
        let distances = curve.stops.enumerated().map { index, stop -> (Int, CGFloat) in
            let dx = axes.x(zoom: stop.zoom, in: rect) - point.x
            let dy = axes.y(value: Double(stop.value), in: rect) - point.y
            return (index, (dx * dx + dy * dy).squareRoot())
        }
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= radius else {
            return nil
        }
        return nearest.0
    }

    /// The curve with a stop at a zoom: the stop there takes the value, or a
    /// new one is added. Returns the stop's index in the new curve.
    static func settingStop(_ curve: ImmersiveMapZoomCurve,
                            zoom: Double,
                            value: Double) -> (curve: ImmersiveMapZoomCurve, index: Int) {
        let others = curve.stops.filter { $0.zoom != zoom }
        let edited = ImmersiveMapZoomCurve(stops: others + [ImmersiveMapZoomCurve.Stop(zoom: zoom, value: Float(value))])
        let index = edited.stops.firstIndex { $0.zoom == zoom } ?? 0
        return (edited, index)
    }

    /// The curve with one stop moved. A stop dragged onto another's zoom
    /// keeps its own zoom and takes only the value, so the drag never
    /// swallows a neighbour. Returns the moved stop's index in the new curve.
    static func movingStop(_ curve: ImmersiveMapZoomCurve,
                           at index: Int,
                           toZoom zoom: Double,
                           value: Double) -> (curve: ImmersiveMapZoomCurve, index: Int) {
        guard curve.stops.indices.contains(index) else {
            return (curve, index)
        }
        let own = curve.stops[index]
        let taken = curve.stops.enumerated().contains { $0.offset != index && $0.element.zoom == zoom }
        let newZoom = taken ? own.zoom : zoom
        var stops = curve.stops
        stops[index] = ImmersiveMapZoomCurve.Stop(zoom: newZoom, value: Float(value))
        let edited = ImmersiveMapZoomCurve(stops: stops)
        let newIndex = edited.stops.firstIndex { $0.zoom == newZoom } ?? index
        return (edited, newIndex)
    }

    /// The curve without one stop, or nil for the last stop: a curve keeps
    /// at least one.
    static func removingStop(_ curve: ImmersiveMapZoomCurve, at index: Int) -> ImmersiveMapZoomCurve? {
        guard curve.stops.count > 1, curve.stops.indices.contains(index) else {
            return nil
        }
        var stops = curve.stops
        stops.remove(at: index)
        return ImmersiveMapZoomCurve(stops: stops)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// A value that follows the camera zoom: stops of a value at a zoom, and a
/// smooth blend between neighbouring stops. Below the first stop the value
/// is the first stop's, above the last the last's. A single value is a
/// curve with one stop, the same at every zoom.
///
/// Between two stops the value runs on a smoothstep of the zoom, the curve
/// `ImmersiveMapZoomFade` runs on, so it starts and arrives at rest: a zoom
/// gesture crossing a stop sees no kink, and a setting reached at a stop
/// holds there instead of overshooting it. Evaluated against the camera zoom
/// each frame, so a zoom gesture plays the change.
///
/// A literal writes either form:
///
///     let density: ImmersiveMapZoomCurve = 0.3
///     let height: ImmersiveMapZoomCurve = [13: 4, 14: 1, 15: 0.15]
public struct ImmersiveMapZoomCurve: Hashable, Sendable {
    public struct Stop: Hashable, Sendable {
        public let zoom: Double
        public let value: Float

        public init(zoom: Double, value: Float) {
            self.zoom = zoom
            self.value = value
        }
    }

    /// The stops, in increasing zoom, never empty.
    public let stops: [Stop]

    /// The same value at every zoom.
    public init(_ value: Float) {
        stops = [Stop(zoom: 0, value: value)]
    }

    /// The stops in any order. Two stops at one zoom would be a jump, which
    /// the curve does not make.
    public init(stops: [Stop]) {
        precondition(stops.isEmpty == false, "A zoom curve needs at least one stop")
        let sorted = stops.sorted { $0.zoom < $1.zoom }
        precondition(zip(sorted, sorted.dropFirst()).allSatisfy { $0.zoom < $1.zoom },
                     "A zoom curve's stops lie at distinct zooms")
        self.stops = sorted
    }

    /// How a curve runs between two stops.
    public enum Interpolation: Hashable, Sendable {
        /// A smoothstep of the zoom from one value to the next: it starts
        /// and arrives at rest.
        case smooth
        /// The same ratio for every step of zoom, the way the map's scale
        /// changes (twice per zoom level): for a length on the ground, so
        /// two stops a few zooms apart follow the map in between. Falls back
        /// to `smooth` where a stop is not above zero.
        case geometric
    }

    /// The value at a camera zoom.
    public func value(atZoom zoom: Double, interpolation: Interpolation = .smooth) -> Float {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if zoom <= first.zoom { return first.value }
        if zoom >= last.zoom { return last.value }
        // The segment the zoom lies in: the first stop past it and the one
        // before. A curve holds a handful of stops, so a linear scan.
        let upper = stops.firstIndex { $0.zoom > zoom } ?? stops.count - 1
        let from = stops[upper - 1]
        let to = stops[upper]
        let t = simd_clamp(Float((zoom - from.zoom) / (to.zoom - from.zoom)), 0, 1)
        if interpolation == .geometric, from.value > 0, to.value > 0 {
            return from.value * pow(to.value / from.value, t)
        }
        let eased = t * t * (3 - 2 * t)
        return from.value + (to.value - from.value) * eased
    }

    /// The value, when the curve is the same at every zoom.
    var constantValue: Float? {
        stops.count == 1 ? stops[0].value : nil
    }
}

extension ImmersiveMapZoomCurve: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Float) {
        self.init(value)
    }
}

extension ImmersiveMapZoomCurve: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self.init(Float(value))
    }
}

extension ImmersiveMapZoomCurve: ExpressibleByDictionaryLiteral {
    /// `[zoom: value, ...]`, in any order.
    public init(dictionaryLiteral elements: (Double, Float)...) {
        self.init(stops: elements.map { Stop(zoom: $0.0, value: $0.1) })
    }
}

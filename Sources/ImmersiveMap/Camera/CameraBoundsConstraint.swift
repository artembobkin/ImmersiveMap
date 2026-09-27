// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The geometry of `CameraSettings.Bounds`. The area the center belongs in is
/// the region in normalized world Mercator, widened on every side by a share
/// of the distance from that side to the edge of the world: all of it below
/// the pull's zoom range, none of it above, and the curve's value in between.
/// A hard edge clamps to the area (`apply`), an elastic one damps a move past
/// it (`resist`) and pulls the center back (`returnStep`). Longitude is
/// measured around the region's middle, so a region across the antimeridian
/// behaves like any other.
struct CameraBoundsConstraint {
    private let centerX: Double
    private let halfWidth: Double
    private let minimumY: Double
    private let maximumY: Double
    private let pullZoomRange: ClosedRange<Double>
    private let pullCurve: ImmersiveMapSettings.CameraSettings.Bounds.PullCurve

    init(bounds: ImmersiveMapSettings.CameraSettings.Bounds) {
        let westX = (bounds.southWest.longitude + 180) / 360
        let eastX = (bounds.northEast.longitude + 180) / 360
        var width = eastX - westX
        if width < 0 {
            width += 1
        }
        width = min(width, 1)
        centerX = westX + width * 0.5
        halfWidth = width * 0.5

        let degreesToRadians = Double.pi / 180
        let southY = ImmersiveMapProjection.worldMercator(latitude: bounds.southWest.latitude * degreesToRadians,
                                                          longitude: 0).y
        let northY = ImmersiveMapProjection.worldMercator(latitude: bounds.northEast.latitude * degreesToRadians,
                                                          longitude: 0).y
        minimumY = min(southY, northY)
        maximumY = max(southY, northY)
        pullZoomRange = bounds.pullZoomRange
        pullCurve = bounds.pullCurve
    }

    /// The area the center belongs in at a zoom. `halfWidth` is measured
    /// from the region's middle and is nil when every longitude is in it.
    private struct Area {
        let halfWidth: Double?
        let lowestY: Double
        let highestY: Double
    }

    private func area(atZoom zoom: Double) -> Area {
        let openShare = 1 - pull(atZoom: zoom)
        let allowedHalfWidth = halfWidth + (0.5 - halfWidth) * openShare
        return Area(halfWidth: allowedHalfWidth < 0.5 ? allowedHalfWidth : nil,
                    lowestY: minimumY * (1 - openShare),
                    highestY: maximumY + (1 - maximumY) * openShare)
    }

    /// The nearest point of the area at `zoom`.
    func apply(to centerWorldMercator: SIMD2<Double>, zoom: Double) -> SIMD2<Double> {
        let area = area(atZoom: zoom)
        var x = centerWorldMercator.x
        if let halfWidth = area.halfWidth {
            let offset = Self.shortOffset(x - centerX)
            x = centerX + min(max(offset, -halfWidth), halfWidth)
        }

        let y = min(max(centerWorldMercator.y, area.lowestY), area.highestY)
        return SIMD2<Double>(ImmersiveMapProjection.wrapNormalizedWorldX(x),
                             ImmersiveMapProjection.clampNormalizedWorldY(y))
    }

    /// Moves the center from `current` toward `proposed` against the elastic
    /// edge: inside the area and back toward it the move is free, past the
    /// edge it is damped so the distance past it approaches
    /// `maximumStretch`, in world units, and never reaches it. A center
    /// already that far out (a zoom can put it there) moves no further out.
    func resist(from current: SIMD2<Double>,
                to proposed: SIMD2<Double>,
                zoom: Double,
                maximumStretch: Double) -> SIMD2<Double> {
        let area = area(atZoom: zoom)
        var x = proposed.x
        if let halfWidth = area.halfWidth {
            let currentOffset = Self.shortOffset(current.x - centerX)
            let proposedOffset = currentOffset + Self.shortOffset(proposed.x - current.x)
            x = centerX + Self.stretch(from: currentOffset,
                                       to: proposedOffset,
                                       lowerEdge: -halfWidth,
                                       upperEdge: halfWidth,
                                       maximumStretch: maximumStretch)
        }

        let y = Self.stretch(from: current.y,
                             to: proposed.y,
                             lowerEdge: area.lowestY,
                             upperEdge: area.highestY,
                             maximumStretch: maximumStretch)
        return SIMD2<Double>(ImmersiveMapProjection.wrapNormalizedWorldX(x),
                             ImmersiveMapProjection.clampNormalizedWorldY(y))
    }

    /// How far the center is from the area, in world units, the short way
    /// around in longitude.
    func distanceOutside(of center: SIMD2<Double>, zoom: Double) -> Double {
        let target = apply(to: center, zoom: zoom)
        return simd_length(SIMD2<Double>(Self.shortOffset(target.x - center.x), target.y - center.y))
    }

    /// One frame of the elastic pull: the center moves `fraction` of the
    /// way to the nearest point of the area, the short way around in
    /// longitude. The second value is the distance left, in world units.
    func returnStep(from center: SIMD2<Double>,
                    zoom: Double,
                    fraction: Double) -> (center: SIMD2<Double>, remainingDistance: Double) {
        let target = apply(to: center, zoom: zoom)
        let gap = SIMD2<Double>(Self.shortOffset(target.x - center.x), target.y - center.y)
        let moved = center + gap * min(max(fraction, 0), 1)
        let next = SIMD2<Double>(ImmersiveMapProjection.wrapNormalizedWorldX(moved.x),
                                 ImmersiveMapProjection.clampNormalizedWorldY(moved.y))
        let remaining = SIMD2<Double>(Self.shortOffset(target.x - next.x), target.y - next.y)
        return (next, simd_length(remaining))
    }

    /// The rubber band on one axis. Past an edge the visible distance `d`
    /// and the distance the drag has travelled `u` are related by
    /// `d = L u / (L + u)`: slope 1 at the edge, tending to `L`. The drag's
    /// travel is recovered from the current distance, so no state is kept
    /// between moves.
    private static func stretch(from current: Double,
                                to proposed: Double,
                                lowerEdge: Double,
                                upperEdge: Double,
                                maximumStretch: Double) -> Double {
        guard maximumStretch > 0 else {
            return min(max(proposed, lowerEdge), upperEdge)
        }

        if proposed > upperEdge, proposed > current {
            let past = max(current - upperEdge, 0)
            guard past < maximumStretch else {
                return current
            }
            let travel = maximumStretch * past / (maximumStretch - past) + (proposed - max(current, upperEdge))
            return upperEdge + maximumStretch * travel / (maximumStretch + travel)
        }
        if proposed < lowerEdge, proposed < current {
            let past = max(lowerEdge - current, 0)
            guard past < maximumStretch else {
                return current
            }
            let travel = maximumStretch * past / (maximumStretch - past) + (min(current, lowerEdge) - proposed)
            return lowerEdge - maximumStretch * travel / (maximumStretch + travel)
        }
        return proposed
    }

    /// A longitude difference taken the short way around the world, in
    /// -0.5..<0.5.
    private static func shortOffset(_ offset: Double) -> Double {
        var wrapped = offset.truncatingRemainder(dividingBy: 1)
        if wrapped >= 0.5 {
            wrapped -= 1
        } else if wrapped < -0.5 {
            wrapped += 1
        }
        return wrapped
    }

    /// How far the reachable area has closed in on the region at a zoom: 0
    /// for the whole world, 1 for the region alone.
    func pull(atZoom zoom: Double) -> Double {
        let lower = pullZoomRange.lowerBound
        let span = pullZoomRange.upperBound - lower
        guard span > Double.leastNonzeroMagnitude else {
            return zoom >= lower ? 1 : 0
        }

        let progress = min(max((zoom - lower) / span, 0), 1)
        return min(max(pullCurve.value(at: progress), 0), 1)
    }
}

extension ImmersiveMapSettings.CameraSettings.Bounds.PullCurve {
    /// The curve's y at `x` in 0...1: the Bezier parameter whose x matches is
    /// found by Newton's method, with bisection where the slope is too flat
    /// for it.
    func value(at x: Double) -> Double {
        if x <= 0 {
            return 0
        }
        if x >= 1 {
            return 1
        }

        var t = x
        for _ in 0..<8 {
            let error = Self.coordinate(t, x1, x2) - x
            if abs(error) < 1e-9 {
                return Self.coordinate(t, y1, y2)
            }
            let slope = Self.derivative(t, x1, x2)
            guard abs(slope) > 1e-6 else {
                break
            }
            t = min(max(t - error / slope, 0), 1)
        }

        var low = 0.0
        var high = 1.0
        t = x
        for _ in 0..<60 {
            let value = Self.coordinate(t, x1, x2)
            if abs(value - x) < 1e-9 {
                break
            }
            if value < x {
                low = t
            } else {
                high = t
            }
            t = (low + high) * 0.5
        }
        return Self.coordinate(t, y1, y2)
    }

    /// One coordinate of the Bezier from 0 to 1 with control values `p1`, `p2`.
    private static func coordinate(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * p1 + 3 * inverse * t * t * p2 + t * t * t
    }

    private static func derivative(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * p1 + 6 * inverse * t * (p2 - p1) + 3 * t * t * (1 - p2)
    }
}

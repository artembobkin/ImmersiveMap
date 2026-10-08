// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

public enum LineJoin: Sendable {
    case bevel
    case miter
    case round
}

public enum LineCap: Sendable {
    case butt
    case square
    case round
}

extension FlattenInput {
    /// Adds a polyline as a filled stroke of the given width.
    ///
    /// - Parameter tolerance: the largest allowed distance between a round join or cap and the true
    ///   circle, in the units of the points.
    public mutating func addLine(
        _ points: [SIMD2<Double>],
        width: Double,
        paint: Int,
        join: LineJoin = .round,
        cap: LineCap = .butt,
        tolerance: Double = 0.25
    ) {
        points.withUnsafeBufferPointer {
            addLine($0, width: width, paint: paint, join: join, cap: cap, tolerance: tolerance)
        }
    }

    /// The stroke is one ring: the left side of the line forwards, then the right side backwards.
    /// All strokes have the same orientation, so overlapping strokes of one paint merge under the
    /// nonzero winding rule. Where the ring overlaps itself (a sharp turn between short segments,
    /// a line that crosses itself) the winding number only grows in magnitude, so no holes appear.
    public mutating func addLine(
        _ points: UnsafeBufferPointer<SIMD2<Double>>,
        width: Double,
        paint: Int,
        join: LineJoin = .round,
        cap: LineCap = .butt,
        tolerance: Double = 0.25
    ) {
        let h = width * 0.5
        guard h > 0, points.count >= 2 else { return }

        // Drop repeated points: every remaining segment has a direction.
        strokePoints.removeAll(keepingCapacity: true)
        strokeRight.removeAll(keepingCapacity: true)
        for p in points where strokePoints.last != p { strokePoints.append(p) }
        let count = strokePoints.count
        guard count >= 2 else { return }

        // The largest arc step that stays within the tolerance.
        let stepAngle: Double = h <= tolerance ? .pi : 2 * acos(1 - tolerance / h)
        let capSteps = max(2, Int((Double.pi / stepAngle).rounded(.up)))

        var a = strokePoints[0]
        var b = strokePoints[1]
        let delta = b - a
        var length = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        var d = delta / length
        if cap == .square { a -= d * h }
        let firstDirection = d
        let firstPoint = a

        beginRing(paint: paint)
        addPoint(x: a.x - d.y * h, y: a.y + d.x * h)

        if count > 2 {
            for i in IndexRange(1, count - 1) {
                let v = b
                let next = strokePoints[i + 1]
                let nextDelta = next - v
                let nextLength = (nextDelta.x * nextDelta.x + nextDelta.y * nextDelta.y).squareRoot()
                let nextD = nextDelta / nextLength
                let cross = d.x * nextD.y - d.y * nextD.x
                let dot = d.x * nextD.x + d.y * nextD.y

                // Collinear segments need no vertex on either side.
                if !(dot > 0 && abs(cross) < 1e-9) {
                    let n0 = SIMD2(-d.y, d.x) * h
                    let n1 = SIMD2(-nextD.y, nextD.x) * h
                    // A turn with a positive cross product has its outer side on the right (-n).
                    let outerIsLeft = cross < 0
                    let outerSign: Double = outerIsLeft ? 1 : -1
                    let o0 = n0 * outerSign
                    let o1 = n1 * outerSign
                    let k = 1 + dot

                    // Inner side: the two offset lines meet in one point when both segments are
                    // long enough. Otherwise go through the vertex itself, which keeps the winding
                    // number equal to that of separate overlapping segments.
                    let reach = k > 1e-6 ? h * abs(cross) / k : Double.infinity
                    let innerFits = reach <= 0.5 * min(length, nextLength)

                    if outerIsLeft {
                        addOuterJoin(at: v, o0, o1, cross: cross, dot: dot, join: join, stepAngle: stepAngle, toRight: false)
                        if innerFits {
                            strokeRight.append(v - (o0 + o1) / k)
                        } else {
                            strokeRight.append(v - o0)
                            strokeRight.append(v)
                            strokeRight.append(v - o1)
                        }
                    } else {
                        if innerFits {
                            let inner = v - (o0 + o1) / k
                            addPoint(x: inner.x, y: inner.y)
                        } else {
                            addPoint(x: v.x - o0.x, y: v.y - o0.y)
                            addPoint(x: v.x, y: v.y)
                            addPoint(x: v.x - o1.x, y: v.y - o1.y)
                        }
                        addOuterJoin(at: v, o0, o1, cross: cross, dot: dot, join: join, stepAngle: stepAngle, toRight: true)
                    }
                }

                b = next
                length = nextLength
                d = nextD
            }
        }

        // The end: left corner, cap, right corner.
        var end = b
        if cap == .square { end += d * h }
        let endNormal = SIMD2(-d.y, d.x) * h
        addPoint(x: end.x + endNormal.x, y: end.y + endNormal.y)
        if cap == .round {
            // Rotating the normal by a negative angle passes through the line direction.
            for s in IndexRange(1, capSteps) {
                let p = end + rotate(endNormal, by: -Double.pi * Double(s) / Double(capSteps))
                addPoint(x: p.x, y: p.y)
            }
        }
        addPoint(x: end.x - endNormal.x, y: end.y - endNormal.y)

        // The right side, backwards.
        var r = strokeRight.count - 1
        while r >= 0 {
            addPoint(x: strokeRight[r].x, y: strokeRight[r].y)
            r -= 1
        }

        // The start: right corner, cap. The ring closes at the left corner.
        let startNormal = SIMD2(-firstDirection.y, firstDirection.x) * h
        addPoint(x: firstPoint.x - startNormal.x, y: firstPoint.y - startNormal.y)
        if cap == .round {
            for s in IndexRange(1, capSteps) {
                let p = firstPoint - rotate(startNormal, by: -Double.pi * Double(s) / Double(capSteps))
                addPoint(x: p.x, y: p.y)
            }
        }
        endRing()
    }

    /// Emits the outer corner of a turn, from offset `o0` to offset `o1` around `v`.
    private mutating func addOuterJoin(
        at v: SIMD2<Double>,
        _ o0: SIMD2<Double>,
        _ o1: SIMD2<Double>,
        cross: Double,
        dot: Double,
        join: LineJoin,
        stepAngle: Double,
        toRight: Bool
    ) {
        emitStrokePoint(v + o0, toRight)
        switch join {
        case .bevel:
            break
        case .miter:
            let k = 1 + dot
            // A miter longer than twice the half width falls back to a bevel.
            if k > 0.5 { emitStrokePoint(v + (o0 + o1) / k, toRight) }
        case .round:
            let angle = atan2(abs(cross), dot)
            let steps = Int((angle / stepAngle).rounded(.up))
            if steps > 1 {
                let step = (cross > 0 ? angle : -angle) / Double(steps)
                for s in IndexRange(1, steps) { emitStrokePoint(v + rotate(o0, by: step * Double(s)), toRight) }
            }
        }
        emitStrokePoint(v + o1, toRight)
    }

    @inline(__always)
    private mutating func emitStrokePoint(_ p: SIMD2<Double>, _ toRight: Bool) {
        if toRight { strokeRight.append(p) } else { addPoint(x: p.x, y: p.y) }
    }
}

@inline(__always)
private func rotate(_ v: SIMD2<Double>, by angle: Double) -> SIMD2<Double> {
    let c = cos(angle), s = sin(angle)
    return SIMD2(v.x * c - v.y * s, v.x * s + v.y * c)
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The polyline operations the road passes apply before tessellation:
/// shifting a line sideways, pulling it back from its ends, cutting it at
/// junctions. Pure functions on points in tile space.
enum RoadPolylineMath {
    /// Shifts a polyline sideways by `offset` tile units (positive to the left
    /// of travel), with mitred corners so the shifted line stays parallel to
    /// the original; the miter is capped so a hairpin does not shoot the
    /// corner off to infinity. Zero offset returns the input.
    static func offsetPolyline(_ points: [SIMD2<Float>], by offset: Float) -> [SIMD2<Float>] {
        guard abs(offset) > 1e-6, points.count >= 2 else { return points }
        var normals: [SIMD2<Float>] = []
        normals.reserveCapacity(points.count - 1)
        for index in 0..<(points.count - 1) {
            let direction = points[index + 1] - points[index]
            let length = simd_length(direction)
            normals.append(length > 1e-6 ? SIMD2<Float>(-direction.y, direction.x) / length : SIMD2<Float>(0, 0))
        }
        var shifted: [SIMD2<Float>] = []
        shifted.reserveCapacity(points.count)
        for index in 0..<points.count {
            let before = index > 0 ? normals[index - 1] : normals[0]
            let after = index < normals.count ? normals[index] : normals[normals.count - 1]
            var miter = before + after
            let miterLength = simd_length(miter)
            if miterLength > 1e-6 {
                miter /= miterLength
                // Projection of the unit miter onto one normal gives the
                // cosine of the half angle; the miter length is its inverse,
                // capped at 2 (a 60 degree turn) so sharp corners stay sane.
                let cosine = max(simd_dot(miter, after), 0.5)
                shifted.append(points[index] + miter * (offset / cosine))
            } else {
                shifted.append(points[index] + after * offset)
            }
        }
        return shifted
    }

    /// Pulls a polyline back from its ends by `inset` tile units along its own
    /// path, consuming whole leading or trailing segments when the inset
    /// exceeds them. Returns nil when the line is shorter than the insets it
    /// is asked for: a stub of paint with no room for a dash is no paint.
    static func insetLineEnds(_ points: [SIMD2<Float>],
                              inset: Float,
                              insetStart: Bool,
                              insetEnd: Bool) -> [SIMD2<Float>]? {
        insetLineEnds(points,
                      startInset: insetStart ? inset : 0,
                      endInset: insetEnd ? inset : 0)
    }

    /// The same, with an inset chosen per end: the paint stops half of the
    /// road it meets short of the junction, and the two ends of one piece
    /// usually meet different roads.
    static func insetLineEnds(_ points: [SIMD2<Float>],
                              startInset: Float,
                              endInset: Float) -> [SIMD2<Float>]? {
        guard startInset > 0 || endInset > 0, points.count >= 2 else {
            return points
        }
        var working = points
        func trim(_ reversed: Bool) -> Bool {
            var remaining = reversed ? endInset : startInset
            guard remaining > 0 else { return true }
            var path = reversed ? Array(working.reversed()) : working
            while path.count >= 2 {
                let segment = path[1] - path[0]
                let length = simd_length(segment)
                if length > remaining {
                    path[0] = path[0] + segment / length * remaining
                    working = reversed ? Array(path.reversed()) : path
                    return true
                }
                remaining -= length
                path.removeFirst()
            }
            return false
        }
        if trim(false) == false {
            return nil
        }
        if trim(true) == false {
            return nil
        }
        return working.count >= 2 ? working : nil
    }

    /// Cuts a line at every interior point where another carriageway meets
    /// it, so a pass that insets its ends (the paint down a road) stops short
    /// of each junction instead of running through it.
    ///
    /// A point is a junction when more than one drive-tier feature touches it.
    /// The endpoints of the fragment are left alone: they are already ends,
    /// and whether they are a genuine end, a tile seam or a junction is
    /// decided by the caller, which knows about clipping.
    static func splitAtJunctions(fragment: ClippedLineFragment,
                                 automobilePointCounts: [RoadConnectionPointKey: Int]) -> [ClippedLineFragment] {
        splitAtJunctionsWithOrigins(fragment: fragment,
                                    automobilePointCounts: automobilePointCounts).map(\.fragment)
    }

    /// The same, with how far along the line each piece begins.
    ///
    /// A dash pattern is cut from arc length, so a piece that continues
    /// another one has to carry on counting where that one stopped: paint
    /// broken at a junction resumes in step on the far side instead of
    /// starting a fresh stroke.
    static func splitAtJunctionsWithOrigins(
        fragment: ClippedLineFragment,
        automobilePointCounts: [RoadConnectionPointKey: Int]
    ) -> [(fragment: ClippedLineFragment, arcLengthOrigin: Float)] {
        let points = fragment.points
        guard points.count > 2 else { return [(fragment, 0)] }

        var pieces: [(fragment: ClippedLineFragment, arcLengthOrigin: Float)] = []
        var current: [SIMD2<Float>] = [points[0]]
        var travelled: Float = 0
        var pieceOrigin: Float = 0
        for index in 1..<points.count {
            travelled += simd_distance(points[index], points[index - 1])
            current.append(points[index])
            let isInterior = index < points.count - 1
            guard isInterior,
                  (automobilePointCounts[RoadConnectionPointKey(point: points[index])] ?? 0) > 1 else {
                continue
            }
            // The piece ends here, and the next one starts at the same point:
            // both are genuine ends, so both get the inset.
            pieces.append((ClippedLineFragment(points: current,
                                               startClipped: pieces.isEmpty ? fragment.startClipped : false,
                                               endClipped: false),
                           pieceOrigin))
            current = [points[index]]
            pieceOrigin = travelled
        }
        guard pieces.isEmpty == false else { return [(fragment, 0)] }
        if current.count >= 2 {
            pieces.append((ClippedLineFragment(points: current,
                                               startClipped: false,
                                               endClipped: fragment.endClipped),
                           pieceOrigin))
        }
        return pieces
    }

    /// The length of a polyline in tile units.
    static func length(of points: [SIMD2<Float>]) -> Float {
        guard points.count >= 2 else {
            return 0.0
        }

        var totalLength: Float = 0.0
        for index in 1..<points.count {
            totalLength += simd_length(points[index] - points[index - 1])
        }
        return totalLength
    }
}

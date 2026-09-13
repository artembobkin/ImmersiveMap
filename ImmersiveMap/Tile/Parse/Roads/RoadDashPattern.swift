// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Cuts a line fragment into the pieces a dashed pass draws: the dashes
/// themselves, each a fragment of its own. A solid pass gets the fragment
/// back whole.
enum RoadDashPattern {
    private static let epsilon: Float = 0.0001

    /// The fragments a pass tessellates: one for a solid style, the dashes
    /// for a dashed one. With `dashResetsPerSegment` the pattern restarts on
    /// every segment of the line and centres its whole dashes on it, pulled
    /// in from the corners; otherwise it runs continuously along the path.
    static func fragments(for fragment: ClippedLineFragment,
                          styleData: ParseGeometryStyleData) -> [ClippedLineFragment] {
        guard styleData.usesDashPattern else {
            return [fragment]
        }
        guard styleData.dashResetsPerSegment == false else {
            guard fragment.points.count >= 2 else {
                return [fragment]
            }

            var segmentedFragments: [ClippedLineFragment] = []
            segmentedFragments.reserveCapacity(fragment.points.count - 1)

            func direction(from start: SIMD2<Float>, to end: SIMD2<Float>) -> SIMD2<Float>? {
                let delta = end - start
                let length = simd_length(delta)
                guard length > epsilon else {
                    return nil
                }
                return delta / length
            }

            func isTurn(previous: SIMD2<Float>, current: SIMD2<Float>) -> Bool {
                let cross = previous.x * current.y - previous.y * current.x
                let dot = previous.x * current.x + previous.y * current.y
                return abs(cross) > 0.001 || dot < 0.999
            }

            let cornerInset = max(Float(styleData.lineWidth), Float(styleData.dashLength))
            for index in 0..<(fragment.points.count - 1) {
                let segmentStart = fragment.points[index]
                let segmentEnd = fragment.points[index + 1]
                guard let segmentDirection = direction(from: segmentStart, to: segmentEnd) else {
                    continue
                }

                var trimmedStart = segmentStart
                var trimmedEnd = segmentEnd

                if index > 0,
                   let previousDirection = direction(from: fragment.points[index - 1], to: segmentStart),
                   isTurn(previous: previousDirection, current: segmentDirection) {
                    trimmedStart += segmentDirection * cornerInset
                }

                if index < fragment.points.count - 2,
                   let nextDirection = direction(from: segmentEnd, to: fragment.points[index + 2]),
                   isTurn(previous: segmentDirection, current: nextDirection) {
                    trimmedEnd -= segmentDirection * cornerInset
                }

                if simd_length(trimmedEnd - trimmedStart) <= epsilon {
                    continue
                }

                segmentedFragments.append(contentsOf: centeredFullDashFragmentsForSegment(start: trimmedStart,
                                                                                          end: trimmedEnd,
                                                                                          dashLength: Float(styleData.dashLength),
                                                                                          dashGap: Float(styleData.dashGap)))
            }
            return segmentedFragments
        }
        return dashedFragments(from: fragment,
                               dashLength: Float(styleData.dashLength),
                               dashGap: Float(styleData.dashGap))
    }

    private static func centeredFullDashFragmentsForSegment(start: SIMD2<Float>,
                                                            end: SIMD2<Float>,
                                                            dashLength: Float,
                                                            dashGap: Float) -> [ClippedLineFragment] {
        let delta = end - start
        let segmentLength = simd_length(delta)
        guard segmentLength > epsilon,
              dashLength > epsilon,
              dashGap > epsilon else {
            return []
        }

        let direction = delta / segmentLength
        let patternLength = dashLength + dashGap
        let dashCount = Int(((segmentLength + dashGap) / patternLength).rounded(.down))
        guard dashCount > 0 else {
            return []
        }

        let occupiedLength = Float(dashCount) * dashLength + Float(max(0, dashCount - 1)) * dashGap
        let leadingInset = max(0, (segmentLength - occupiedLength) * 0.5)
        let firstDashStart = start + direction * leadingInset

        var dashed: [ClippedLineFragment] = []
        dashed.reserveCapacity(dashCount)
        for index in 0..<dashCount {
            let offset = Float(index) * patternLength
            let dashStart = firstDashStart + direction * offset
            let dashEnd = dashStart + direction * dashLength
            dashed.append(ClippedLineFragment(points: [dashStart, dashEnd],
                                             startClipped: false,
                                             endClipped: false))
        }
        return dashed
    }

    private static func dashedFragments(from fragment: ClippedLineFragment,
                                        dashLength: Float,
                                        dashGap: Float) -> [ClippedLineFragment] {
        guard fragment.points.count >= 2,
              dashLength > epsilon,
              dashGap > epsilon else {
            return [fragment]
        }

        var dashed: [ClippedLineFragment] = []
        var currentDashPoints: [SIMD2<Float>] = []
        currentDashPoints.reserveCapacity(fragment.points.count)

        var isDash = true
        var remainingPatternLength = dashLength
        var dashStartedAtFragmentStart = true

        func pointsEqual(_ lhs: SIMD2<Float>, _ rhs: SIMD2<Float>) -> Bool {
            abs(lhs.x - rhs.x) <= epsilon && abs(lhs.y - rhs.y) <= epsilon
        }

        func appendPointIfNeeded(_ point: SIMD2<Float>) {
            if let last = currentDashPoints.last, pointsEqual(last, point) {
                return
            }
            currentDashPoints.append(point)
        }

        func finalizeDash(endedAtFragmentEnd: Bool) {
            guard currentDashPoints.count >= 2 else {
                currentDashPoints.removeAll(keepingCapacity: true)
                return
            }
            dashed.append(ClippedLineFragment(points: currentDashPoints,
                                             startClipped: dashStartedAtFragmentStart ? fragment.startClipped : false,
                                             endClipped: endedAtFragmentEnd ? fragment.endClipped : false))
            currentDashPoints.removeAll(keepingCapacity: true)
        }

        for index in 0..<(fragment.points.count - 1) {
            let segmentStart = fragment.points[index]
            let segmentEnd = fragment.points[index + 1]
            let segmentDelta = segmentEnd - segmentStart
            let segmentLength = simd_length(segmentDelta)
            guard segmentLength > epsilon else {
                continue
            }

            let direction = segmentDelta / segmentLength
            var currentPoint = segmentStart
            var remainingSegmentLength = segmentLength

            while remainingSegmentLength > epsilon {
                let traveledLength = min(remainingPatternLength, remainingSegmentLength)
                let nextPoint = currentPoint + direction * traveledLength
                let reachesFragmentEnd = index == fragment.points.count - 2
                    && remainingSegmentLength - traveledLength <= epsilon

                if isDash {
                    if currentDashPoints.isEmpty {
                        appendPointIfNeeded(currentPoint)
                    }
                    appendPointIfNeeded(nextPoint)
                }

                currentPoint = nextPoint
                remainingSegmentLength -= traveledLength
                remainingPatternLength -= traveledLength

                if remainingPatternLength <= epsilon {
                    if isDash {
                        finalizeDash(endedAtFragmentEnd: reachesFragmentEnd)
                    }
                    isDash.toggle()
                    remainingPatternLength = isDash ? dashLength : dashGap
                    dashStartedAtFragmentStart = false
                }
            }
        }

        if isDash, currentDashPoints.isEmpty == false {
            finalizeDash(endedAtFragmentEnd: true)
        }

        return dashed
    }
}

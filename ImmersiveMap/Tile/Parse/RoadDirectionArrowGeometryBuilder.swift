// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

struct RoadDirectionArrowGeometryBuilder {
    private static let epsilon: Float = 0.0001
    private static let minimumFragmentLengthFactor: Float = 4.5
    private static let minimumFragmentLength: Float = 96.0
    private static let repeatStep: Float = 420.0
    private static let turnThresholdRadians: Float = .pi / 4.0

    func buildPolygons(points: [SIMD2<Float>],
                       lineWidth: Float,
                       tileExtent: Float) -> [TileMvtParser.ParsedPolygon] {
        guard points.count >= 2 else {
            return []
        }

        let renderPoints = points.map { SIMD2<Float>($0.x, tileExtent - $0.y) }
        let totalLength = polylineLength(points: renderPoints)
        let minimumFragmentLength = max(Self.minimumFragmentLength, lineWidth * Self.minimumFragmentLengthFactor)
        guard totalLength >= minimumFragmentLength else {
            return []
        }

        let metrics = ArrowMetrics(lineWidth: lineWidth)
        let endInset = max(metrics.totalLength, lineWidth * 1.5)
        let usableLength = totalLength - endInset * 2.0
        guard usableLength > Self.epsilon else {
            return []
        }

        let placements: [Float]
        if usableLength <= Self.repeatStep {
            placements = [totalLength * 0.5]
        } else {
            let arrowCount = Int(floor(usableLength / Self.repeatStep)) + 1
            let actualStep = usableLength / Float(max(1, arrowCount - 1))
            placements = (0..<arrowCount).map { endInset + Float($0) * actualStep }
        }

        var polygons: [TileMvtParser.ParsedPolygon] = []
        polygons.reserveCapacity(placements.count * 2)

        let turnCheckTolerance = max(lineWidth, metrics.totalLength * 0.5)
        for distance in placements {
            guard isAwayFromSharpTurn(distance: distance,
                                      tolerance: turnCheckTolerance,
                                      points: renderPoints) else {
                continue
            }
            guard let sample = sample(atDistance: distance, points: renderPoints) else {
                continue
            }
            polygons.append(contentsOf: makeArrowPolygons(center: sample.position,
                                                          tangent: sample.tangent,
                                                          metrics: metrics))
        }

        return polygons
    }

    private func makeArrowPolygons(center: SIMD2<Float>,
                                   tangent: SIMD2<Float>,
                                   metrics: ArrowMetrics) -> [TileMvtParser.ParsedPolygon] {
        let normal = SIMD2<Float>(-tangent.y, tangent.x)
        let tailHalfWidth = metrics.tailWidth * 0.5
        let headHalfWidth = metrics.headWidth * 0.5

        let tailStart = center - tangent * (metrics.totalLength * 0.5)
        let tailEnd = tailStart + tangent * metrics.tailLength
        let tip = tailStart + tangent * metrics.totalLength

        let tailPolygon = TileMvtParser.ParsedPolygon(
            vertices: [
                quantize(tailStart + normal * tailHalfWidth),
                quantize(tailStart - normal * tailHalfWidth),
                quantize(tailEnd + normal * tailHalfWidth),
                quantize(tailEnd - normal * tailHalfWidth)
            ],
            indices: [0, 2, 1, 1, 2, 3]
        )

        let headPolygon = TileMvtParser.ParsedPolygon(
            vertices: [
                quantize(tailEnd + normal * headHalfWidth),
                quantize(tailEnd - normal * headHalfWidth),
                quantize(tip)
            ],
            indices: [0, 2, 1]
        )

        return [tailPolygon, headPolygon]
    }

    private func isAwayFromSharpTurn(distance: Float,
                                     tolerance: Float,
                                     points: [SIMD2<Float>]) -> Bool {
        guard points.count >= 3 else {
            return true
        }

        var traversed: Float = 0.0
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            let delta = end - start
            let segmentLength = simd_length(delta)
            guard segmentLength > Self.epsilon else {
                continue
            }

            if index > 1,
               abs(distance - traversed) <= tolerance,
               turnAngle(previous: points[index - 2], current: start, next: end) > Self.turnThresholdRadians {
                return false
            }

            traversed += segmentLength

            if index < points.count - 1,
               abs(distance - traversed) <= tolerance,
               turnAngle(previous: start, current: end, next: points[index + 1]) > Self.turnThresholdRadians {
                return false
            }
        }

        return true
    }

    private func turnAngle(previous: SIMD2<Float>,
                           current: SIMD2<Float>,
                           next: SIMD2<Float>) -> Float {
        let incoming = simd_normalize(current - previous)
        let outgoing = simd_normalize(next - current)
        guard incoming.x.isFinite,
              incoming.y.isFinite,
              outgoing.x.isFinite,
              outgoing.y.isFinite else {
            return 0.0
        }
        let dot = max(-1.0, min(1.0, simd_dot(incoming, outgoing)))
        return acos(dot)
    }

    private func sample(atDistance distance: Float,
                        points: [SIMD2<Float>]) -> (position: SIMD2<Float>, tangent: SIMD2<Float>)? {
        guard let first = points.first else {
            return nil
        }
        guard points.count >= 2 else {
            return (first, SIMD2<Float>(1.0, 0.0))
        }

        var traversed: Float = 0.0
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            let delta = end - start
            let segmentLength = simd_length(delta)
            guard segmentLength > Self.epsilon else {
                continue
            }

            let nextTraversed = traversed + segmentLength
            if distance <= nextTraversed + Self.epsilon {
                let t = max(0.0, min(1.0, (distance - traversed) / segmentLength))
                return (start + delta * t, delta / segmentLength)
            }
            traversed = nextTraversed
        }

        let fallbackDelta = (points.last ?? first) - points[points.count - 2]
        let fallbackLength = simd_length(fallbackDelta)
        guard fallbackLength > Self.epsilon else {
            return nil
        }
        return (points.last ?? first, fallbackDelta / fallbackLength)
    }

    private func polylineLength(points: [SIMD2<Float>]) -> Float {
        guard points.count >= 2 else {
            return 0.0
        }

        var total: Float = 0.0
        for index in 1..<points.count {
            total += simd_length(points[index] - points[index - 1])
        }
        return total
    }

    private func quantize(_ point: SIMD2<Float>) -> SIMD2<Int16> {
        SIMD2<Int16>(Int16(clamping: Int(point.x.rounded())),
                     Int16(clamping: Int(point.y.rounded())))
    }
}

private struct ArrowMetrics {
    let totalLength: Float
    let headLength: Float
    let tailLength: Float
    let tailWidth: Float
    let headWidth: Float

    init(lineWidth: Float) {
        totalLength = min(64.0, max(26.0, lineWidth * 3.0))
        headLength = totalLength * 0.42
        tailLength = max(totalLength - headLength, totalLength * 0.58)
        tailWidth = min(9.0, max(3.5, lineWidth * 0.22))
        headWidth = tailWidth * 2.0
    }
}

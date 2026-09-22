// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Decides which of a tile's building candidates are extruded, once every
/// footprint of the tile is known: duplicates go, a part nested inside a
/// taller part of the same building goes, and a ground outline that
/// engulfs the articulated parts of other buildings is clamped down to a
/// pedestal.
enum BuildingExtrusionResolver {
    /// Wraps a candidate with its footprint bbox and area, both computed exactly
    /// once. The passes below compare O(n^2) candidate pairs; recomputing these
    /// per pair (instead of per candidate) used to dominate tile-parse CPU time.
    private struct MeasuredCandidate {
        let candidate: BuildingExtrusionCandidate
        let bounds: FootprintBounds
        let area: Float
    }

    static func resolveExterior(_ candidates: [BuildingExtrusionCandidate]) -> [BuildingExtrusionCandidate] {
        guard candidates.count > 1 else { return candidates }

        let measuredCandidates = candidates.map { candidate in
            MeasuredCandidate(candidate: candidate,
                              bounds: footprintBounds(candidate.clippedExterior),
                              area: polygonAreaMagnitude(candidate.clippedExterior))
        }

        var filtered: [MeasuredCandidate] = []
        filtered.reserveCapacity(measuredCandidates.count)

        let groupedByBuilding = Dictionary(grouping: measuredCandidates, by: \.candidate.buildingId)
        for (_, buildingCandidates) in groupedByBuilding {
            let uniqueCandidates = deduplicate(buildingCandidates)
            filtered.append(contentsOf: suppressNested(uniqueCandidates))
        }

        return clampEnvelopes(filtered).map(\.candidate)
    }

    /// Some sources (e.g. OpenMapTiles for St. Basil's Cathedral) emit a tall
    /// ground-level OUTER OUTLINE of a parts-modeled building without the usual
    /// `hide_3d` flag. Extruded as-is it becomes one solid box that engulfs the
    /// individually-heighted towers/domes inside it. Detect such an envelope - a
    /// base-0 candidate whose footprint encloses many stacked (base>0) parts from
    /// OTHER buildings - and clamp its top down, leaving a solid pedestal while
    /// the parts articulate everything above.
    ///
    /// Two kinds of buildings meet that footprint test, and only one may be
    /// clamped. A parts-modeled landmark (St. Basil's, the Kremlin towers) is a
    /// hull: its stacked parts top out AT its declared height - the outline's top
    /// IS the tallest part's tip. A real solid building decorated with rooftop
    /// parts (Moscow's Four Seasons block) is the opposite: its roof slabs and
    /// lanterns sit entirely ABOVE the outline's top. So a significant part
    /// wholly above the top vetoes the clamp, and otherwise the clamp level
    /// descends from the highest significant part down a chain of
    /// height-overlapping parts, stopping at the first vertical gap - a stray
    /// low canopy disconnected from the chain cannot drag the building down to
    /// its base. Tiny parts (chimneys, crosses, dormers) are ignored throughout:
    /// a footprint below `envelopeClampSignificanceRatio` of the envelope can
    /// neither veto nor stand in for removed walls.
    private static let envelopeClampSignificanceRatio: Float = 0.02
    /// Largest vertical gap allowed between parts of the chain, as a fraction of
    /// the envelope height: it smooths over height quantization in the data
    /// without letting the chain jump across a real void.
    private static let envelopeClampChainGapRatio: Float = 0.05

    private static func clampEnvelopes(_ candidates: [MeasuredCandidate]) -> [MeasuredCandidate] {
        let minEnclosedParts = 4
        guard candidates.count > minEnclosedParts else { return candidates }

        let baseEpsilon: Float = 0.5
        // Only stacked (base>0) parts can witness an envelope; base-0 candidates
        // never enclose themselves because the outer pass skips base>0 entries.
        let stackedIndices = candidates.indices.filter { candidates[$0].candidate.baseHeight > baseEpsilon }
        guard stackedIndices.count >= minEnclosedParts else { return candidates }

        return candidates.map { measured in
            let candidate = measured.candidate
            guard candidate.baseHeight <= baseEpsilon else { return measured }

            let chainTolerance = max(envelopeClampChainGapRatio * candidate.topHeight, 1)
            var enclosedSpans: [(base: Float, top: Float)] = []
            var hasSignificantPartAboveTop = false
            for other in stackedIndices {
                let part = candidates[other]
                guard part.candidate.buildingId != candidate.buildingId,
                      part.area >= envelopeClampSignificanceRatio * measured.area,
                      part.bounds.isInsideOrEqual(to: measured.bounds),
                      isRingContained(part.candidate.clippedExterior, in: candidate.clippedExterior) else {
                    continue
                }
                if part.candidate.baseHeight >= candidate.topHeight - chainTolerance {
                    hasSignificantPartAboveTop = true
                    break
                }
                enclosedSpans.append((part.candidate.baseHeight, part.candidate.topHeight))
            }

            guard hasSignificantPartAboveTop == false,
                  enclosedSpans.count >= minEnclosedParts,
                  var level = enclosedSpans.map(\.top).max() else { return measured }

            var descended = true
            while descended {
                descended = false
                for span in enclosedSpans where span.base < level && span.top + chainTolerance >= level {
                    level = span.base
                    descended = true
                }
            }

            let clampedTop = max(candidate.baseHeight, level)
            guard clampedTop < candidate.topHeight else { return measured }

            let clamped = BuildingExtrusionCandidate(
                styleKey: candidate.styleKey,
                buildingId: candidate.buildingId,
                footprintSignature: candidate.footprintSignature,
                clippedExterior: candidate.clippedExterior,
                clippedInteriors: candidate.clippedInteriors,
                unclippedExterior: candidate.unclippedExterior,
                hasUnclippedInteriorRings: candidate.hasUnclippedInteriorRings,
                roof: candidate.roof,
                roofInfo: nil,
                baseHeight: candidate.baseHeight,
                topHeight: clampedTop
            )
            return MeasuredCandidate(candidate: clamped,
                                     bounds: measured.bounds,
                                     area: measured.area)
        }
    }

    private static func deduplicate(_ candidates: [MeasuredCandidate]) -> [MeasuredCandidate] {
        var seen = Set<CandidateKey>()
        var unique: [MeasuredCandidate] = []
        unique.reserveCapacity(candidates.count)

        for measured in candidates {
            let key = CandidateKey(candidate: measured.candidate)
            if seen.insert(key).inserted {
                unique.append(measured)
            }
        }

        return unique
    }

    private static func suppressNested(_ candidates: [MeasuredCandidate]) -> [MeasuredCandidate] {
        guard candidates.count > 1 else { return candidates }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            if lhs.area != rhs.area {
                return lhs.area > rhs.area
            }
            if lhs.candidate.baseHeight != rhs.candidate.baseHeight {
                return lhs.candidate.baseHeight < rhs.candidate.baseHeight
            }
            return lhs.candidate.topHeight > rhs.candidate.topHeight
        }

        var kept: [MeasuredCandidate] = []
        kept.reserveCapacity(sortedCandidates.count)

        for measured in sortedCandidates {
            let isNested = kept.contains { container in
                measured.candidate.baseHeight >= container.candidate.baseHeight
                    && measured.candidate.topHeight <= container.candidate.topHeight
                    && measured.bounds.isInsideOrEqual(to: container.bounds)
                    && isRingContained(measured.candidate.clippedExterior, in: container.candidate.clippedExterior)
            }
            if isNested == false {
                kept.append(measured)
            }
        }

        return kept
    }

    private static func polygonAreaMagnitude(_ ring: [SIMD2<Float>]) -> Float {
        guard ring.count >= 3 else { return 0 }
        var sum: Float = 0
        for index in 0..<ring.count {
            let next = (index + 1) % ring.count
            sum += ring[index].x * ring[next].y - ring[next].x * ring[index].y
        }
        return abs(sum) * 0.5
    }

    private static func isRingContained(_ ring: [SIMD2<Float>], in container: [SIMD2<Float>]) -> Bool {
        guard ring.isEmpty == false, container.count >= 3 else {
            return false
        }

        return ring.allSatisfy { point in
            pointInRing(point, ring: container)
        }
    }

    private static func pointInRing(_ point: SIMD2<Float>, ring: [SIMD2<Float>]) -> Bool {
        guard ring.count >= 3 else { return false }

        let epsilon: Float = 0.001
        var isInside = false
        var previous = ring[ring.count - 1]
        for current in ring {
            if pointOnSegment(point, a: previous, b: current, epsilon: epsilon) {
                return true
            }

            // The crossing guard above already rejects edges with
            // previous.y == current.y, so the division is safe; clamping the
            // denominator would flip its sign for downward edges and turn the
            // whole test into a coin flip on concave rings.
            let intersects = ((current.y > point.y) != (previous.y > point.y))
                && (point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x)
            if intersects {
                isInside.toggle()
            }
            previous = current
        }

        return isInside
    }

    private static func pointOnSegment(_ point: SIMD2<Float>,
                                       a: SIMD2<Float>,
                                       b: SIMD2<Float>,
                                       epsilon: Float) -> Bool {
        let ab = b - a
        let ap = point - a
        let cross = abs(ab.x * ap.y - ab.y * ap.x)
        if cross > epsilon {
            return false
        }

        let dot = simd_dot(ap, ab)
        if dot < -epsilon {
            return false
        }

        let lengthSquared = simd_dot(ab, ab)
        if dot - lengthSquared > epsilon {
            return false
        }

        return true
    }

    private static func footprintBounds(_ ring: [SIMD2<Float>]) -> FootprintBounds {
        guard let first = ring.first else {
            return FootprintBounds(minX: 0, minY: 0, maxX: 0, maxY: 0)
        }

        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in ring.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return FootprintBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private struct FootprintBounds {
        let minX: Float
        let minY: Float
        let maxX: Float
        let maxY: Float

        func isInsideOrEqual(to other: FootprintBounds) -> Bool {
            let epsilon: Float = 0.001
            return minX >= other.minX - epsilon
                && minY >= other.minY - epsilon
                && maxX <= other.maxX + epsilon
                && maxY <= other.maxY + epsilon
        }
    }

    private struct CandidateKey: Hashable {
        let buildingId: UInt64
        let footprintSignature: BuildingFootprintSignature
        let baseHeightBits: UInt32
        let topHeightBits: UInt32

        init(candidate: BuildingExtrusionCandidate) {
            self.buildingId = candidate.buildingId
            self.footprintSignature = candidate.footprintSignature
            self.baseHeightBits = candidate.baseHeight.bitPattern
            self.topHeightBits = candidate.topHeight.bitPattern
        }
    }
}

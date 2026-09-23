// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Decides which of a tile's building candidates are extruded, once every
/// footprint of the tile is known: duplicates go, a part nested inside a
/// taller part of the same building goes, an outline that ground-standing
/// parts already cover goes, a ground outline that engulfs the
/// articulated parts of other buildings is clamped down to a pedestal, and
/// a volume hidden inside the volumes kept around it goes.
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

        let clamped = clampEnvelopes(dropOutlinesCoveredByParts(filtered))
        return dropVolumesHiddenInsideOthers(clamped).map(\.candidate)
    }

    /// Share of a volume's footprint that must lie inside kept volumes, each
    /// starting no higher and reaching no lower, for the volume to go.
    private static let hiddenVolumeCoverage: Float = 0.95

    /// A volume that sits wholly inside the volumes kept around it is never
    /// seen, except where its lid lies in the plane of theirs: there the two
    /// triangulations flicker through each other. Only such volumes are
    /// measured: one hidden under taller volumes costs nothing to keep. Sources ship such volumes
    /// on their own (two outlines of one building mapped twice, a part inside
    /// its outline at the outline's height, two parts at one height over the
    /// same ground), so a candidate whose footprint lies, to
    /// `hiddenVolumeCoverage`, inside kept candidates that start at or below
    /// its base and reach at least its top is left out. The candidates are
    /// visited from the largest footprint down (the taller, then the lower
    /// based, then the lower building id first on a tie), so of two
    /// identical volumes one stays, the same one on every parse.
    private static func dropVolumesHiddenInsideOthers(_ candidates: [MeasuredCandidate]) -> [MeasuredCandidate] {
        guard candidates.count > 1 else { return candidates }
        let heightEpsilon: Float = 0.01
        let ordered = candidates.enumerated().sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            if left.area != right.area {
                return left.area > right.area
            }
            if left.candidate.topHeight != right.candidate.topHeight {
                return left.candidate.topHeight > right.candidate.topHeight
            }
            if left.candidate.baseHeight != right.candidate.baseHeight {
                return left.candidate.baseHeight < right.candidate.baseHeight
            }
            if left.candidate.buildingId != right.candidate.buildingId {
                return left.candidate.buildingId < right.candidate.buildingId
            }
            return lhs.offset < rhs.offset
        }
        var kept: [MeasuredCandidate] = []
        kept.reserveCapacity(candidates.count)
        var keptOffsets: [Int] = []
        keptOffsets.reserveCapacity(candidates.count)
        var keptGrid = BoundsGrid()
        for (offset, measured) in ordered {
            let enclosing = keptGrid.indices(near: measured.bounds).map { kept[$0] }.filter { other in
                other.candidate.baseHeight <= measured.candidate.baseHeight + heightEpsilon
                    && other.candidate.topHeight >= measured.candidate.topHeight - heightEpsilon
                    && other.bounds.intersects(measured.bounds)
            }
            // Only a lid in the plane of another lid flickers. A volume hidden
            // under taller ones is not seen either way, so it is not worth a
            // coverage measurement.
            let sharesLidPlane = enclosing.contains {
                abs($0.candidate.topHeight - measured.candidate.topHeight) <= heightEpsilon
            }
            if sharesLidPlane == false
                || isCovered(measured, by: enclosing, atLeast: hiddenVolumeCoverage) == false {
                keptGrid.insert(kept.count, bounds: measured.bounds)
                kept.append(measured)
                keptOffsets.append(offset)
            }
        }
        // Back to the tile's order, so the mesh order does not depend on
        // which volumes went.
        return zip(keptOffsets, kept).sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Share of an outline's footprint that ground-standing parts must cover
    /// for the outline to go.
    private static let partCoverageToDropOutline: Float = 0.9
    /// Samples thrown over a footprint's bounds to measure coverage, and the
    /// denser set used when too few would land inside a thin or holed
    /// footprint. The samples follow the R2 low-discrepancy sequence rather
    /// than a regular grid: a grid of 12 by 12 read a courtyard block 95
    /// percent covered as 84 percent, its lines falling in step with the
    /// walls, while R2 points never line up with a straight wall and hold
    /// the estimate within a few percent from a couple of hundred samples.
    /// Only footprints that overlap a possible cover are sampled at all.
    private static let coverageSampleCount = 256
    private static let denseCoverageSampleCount = 1024
    private static let minimumCoverageSamples = 64
    /// The R2 sequence's steps: the inverse plastic number and its square.
    private static let r2StepX: Float = 0.754_877_67
    private static let r2StepY: Float = 0.569_840_29
    /// How far, as a share of its larger side, a footprint may reach out of
    /// the box around its covers and still be tested: parts often trace an
    /// outline a few units inside it.
    private static let coverageBoundsMargin: Float = 0.03

    /// Simple 3D Buildings: once a building is modelled with parts, its
    /// outline is not drawn, the parts are. A source that names which
    /// outline owns which part lets the reader drop the outline by identity
    /// (`BuildingFeatureReader.partInfo`), and an outline that repeats a part
    /// ring for ring goes by its footprint signature. A source with neither
    /// (the Protomaps basemap ships no building id) still ships the outline
    /// next to parts that trace it with a vertex more or less and a
    /// differently drawn courtyard. Extruded together, the outline and the
    /// part that reaches the same height put two lids in one plane, and
    /// their different triangulations flicker through each other as stray
    /// triangles. So an outline whose footprint is covered, to
    /// `partCoverageToDropOutline`, by parts standing on the ground is left
    /// out. Parts that float (a roof slab, a lantern) never count: they do
    /// not replace the walls below them.
    private static func dropOutlinesCoveredByParts(_ candidates: [MeasuredCandidate]) -> [MeasuredCandidate] {
        let baseEpsilon: Float = 0.5
        var groundParts = BoundsGrid()
        for (index, measured) in candidates.enumerated()
        where measured.candidate.isPart && measured.candidate.baseHeight <= baseEpsilon {
            groundParts.insert(index, bounds: measured.bounds)
        }
        guard groundParts.isEmpty == false else { return candidates }

        return candidates.filter { measured in
            guard measured.candidate.isPart == false else { return true }
            let overlapping = groundParts.indices(near: measured.bounds)
                .map { candidates[$0] }
                .filter { $0.bounds.intersects(measured.bounds) }
            guard overlapping.isEmpty == false else { return true }
            return isCovered(measured, by: overlapping, atLeast: partCoverageToDropOutline) == false
        }
    }

    /// Whether at least `share` of the candidate's footprint (exterior minus
    /// courtyards) lies inside the covers, measured on low-discrepancy
    /// samples over its bounds. The walk stops once the misses rule the
    /// answer out, so a volume that plainly stands out of its neighbours
    /// costs a handful of samples.
    private static func isCovered(_ candidate: MeasuredCandidate,
                                  by covers: [MeasuredCandidate],
                                  atLeast share: Float) -> Bool {
        let bounds = candidate.bounds
        let width = bounds.maxX - bounds.minX
        let height = bounds.maxY - bounds.minY
        guard width > 0, height > 0, candidate.area > 0, covers.isEmpty == false else { return false }
        // The common case needs no samples: a footprint standing wholly
        // inside one cover (a rooftop part in its building's outline).
        if covers.contains(where: { isWhollyInside(candidate, $0) }) {
            return true
        }
        // Cheap rejection first: a footprint mostly inside the covers lies,
        // up to a thin margin, inside the box around them. A neighbour whose
        // box merely touches this one fails here without a single sample.
        let margin = coverageBoundsMargin * max(width, height)
        let coverBounds = covers.dropFirst().reduce(covers[0].bounds) { $0.union($1.bounds) }
        guard bounds.minX >= coverBounds.minX - margin, bounds.maxX <= coverBounds.maxX + margin,
              bounds.minY >= coverBounds.minY - margin, bounds.maxY <= coverBounds.maxY + margin else {
            return false
        }
        // The expected number of samples inside the footprint sets how many
        // misses the share allows. A thin or holed footprint gets the finer
        // grid, so the estimate rests on enough samples.
        let fillRatio = min(1, candidate.area / (width * height))
        var total = coverageSampleCount
        if fillRatio * Float(total) < Float(minimumCoverageSamples) {
            total = denseCoverageSampleCount
        }
        let allowedMisses = Int(((1 - share) * fillRatio * Float(total)).rounded(.up))
        // Every prefix of the R2 sequence is spread over the whole box, so an
        // uncovered corner shows up in the first samples.
        var unitX: Float = 0.5
        var unitY: Float = 0.5
        var inside = 0
        var misses = 0
        for _ in 0..<total {
            unitX += r2StepX
            unitY += r2StepY
            unitX -= unitX.rounded(.down)
            unitY -= unitY.rounded(.down)
            let point = SIMD2<Float>(bounds.minX + unitX * width, bounds.minY + unitY * height)
            guard isInFootprint(point, of: candidate.candidate) else { continue }
            inside += 1
            if covers.contains(where: { isInFootprint(point, of: $0.candidate) }) == false {
                misses += 1
                if misses > allowedMisses {
                    return false
                }
            }
        }
        guard inside > 0 else { return false }
        return Float(inside - misses) >= share * Float(inside)
    }

    /// Every vertex of the candidate's exterior inside the cover's footprint
    /// (its exterior and none of its courtyards), and no courtyard of the
    /// cover reaching into the candidate. Exact for the convex and the
    /// gently concave footprints buildings have, and it only ever answers
    /// yes for a footprint that is inside.
    private static func isWhollyInside(_ candidate: MeasuredCandidate, _ cover: MeasuredCandidate) -> Bool {
        guard candidate.bounds.isInsideOrEqual(to: cover.bounds) else { return false }
        let exterior = candidate.candidate.clippedExterior
        guard exterior.allSatisfy({ isInFootprint($0, of: cover.candidate) }) else { return false }
        return cover.candidate.clippedInteriors.allSatisfy { courtyard in
            courtyard.contains { pointInRing($0, ring: exterior) } == false
        }
    }

    private static func isInFootprint(_ point: SIMD2<Float>, of candidate: BuildingExtrusionCandidate) -> Bool {
        pointInRing(point, ring: candidate.clippedExterior)
            && candidate.clippedInteriors.contains { pointInRing(point, ring: $0) } == false
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
                isPart: candidate.isPart,
                footprintSignature: candidate.footprintSignature,
                clippedExterior: candidate.clippedExterior,
                clippedInteriors: candidate.clippedInteriors,
                roof: candidate.roof,
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

    /// A uniform grid over tile space that finds the candidates whose boxes
    /// may meet a given box, so the coverage passes compare a footprint with
    /// its neighbourhood instead of with every building of the tile.
    private struct BoundsGrid {
        private static let cellSize: Float = 256
        private var cells: [Int64: [Int]] = [:]

        var isEmpty: Bool {
            cells.isEmpty
        }

        mutating func insert(_ index: Int, bounds: FootprintBounds) {
            forEachCell(of: bounds) { cells[$0, default: []].append(index) }
        }

        /// Every index stored in a cell the box touches, each once, in
        /// ascending order.
        func indices(near bounds: FootprintBounds) -> [Int] {
            var found: [Int] = []
            forEachCell(of: bounds) { key in
                if let stored = cells[key] {
                    found.append(contentsOf: stored)
                }
            }
            guard found.count > 1 else { return found }
            found.sort()
            var unique: [Int] = []
            unique.reserveCapacity(found.count)
            for index in found where unique.last != index {
                unique.append(index)
            }
            return unique
        }

        private func forEachCell(of bounds: FootprintBounds, _ body: (Int64) -> Void) {
            let minColumn = Int64((bounds.minX / Self.cellSize).rounded(.down))
            let maxColumn = Int64((bounds.maxX / Self.cellSize).rounded(.down))
            let minRow = Int64((bounds.minY / Self.cellSize).rounded(.down))
            let maxRow = Int64((bounds.maxY / Self.cellSize).rounded(.down))
            for row in minRow...maxRow {
                for column in minColumn...maxColumn {
                    body(row &* 1_000_003 &+ column)
                }
            }
        }
    }

    private struct FootprintBounds {
        let minX: Float
        let minY: Float
        let maxX: Float
        let maxY: Float

        func union(_ other: FootprintBounds) -> FootprintBounds {
            FootprintBounds(minX: min(minX, other.minX), minY: min(minY, other.minY),
                            maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
        }

        func intersects(_ other: FootprintBounds) -> Bool {
            minX <= other.maxX && maxX >= other.minX && minY <= other.maxY && maxY >= other.minY
        }

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

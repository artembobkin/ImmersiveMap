// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// A building footprint reduced to a value two features of the same shape
/// share whatever their winding or starting vertex: how a building outline
/// is told apart from the part that repeats it, and how a duplicate
/// candidate is dropped.
struct BuildingFootprintSignature: Hashable {
    let exterior: [UInt64]
    let interiors: [[UInt64]]

    init(exterior: [UInt64], interiors: [[UInt64]]) {
        self.exterior = exterior
        self.interiors = interiors
    }

    /// Nil for a polygon whose exterior has fewer than three distinct
    /// points. The canonical rotation is O(n^2) in ring vertices, so this is
    /// asked only where a signature can match something.
    init?(polygon: Polygon) {
        guard let exterior = Self.canonicalRingSignature(polygon.exteriorRing) else {
            return nil
        }
        let interiors = polygon.interiorRings.compactMap(Self.canonicalRingSignature)
            .sorted(by: Self.lexicographicallyLess)
        self.init(exterior: exterior, interiors: interiors)
    }

    private static func canonicalRingSignature(_ ring: [Point]) -> [UInt64]? {
        let sanitized = sanitizeRing(ring)
        guard sanitized.count >= 3 else {
            return nil
        }

        let forward = sanitized.map(packPoint)
        let backward = Array(forward.reversed())
        let forwardCandidate = canonicalRotation(forward)
        let backwardCandidate = canonicalRotation(backward)
        return lexicographicallyLess(forwardCandidate, backwardCandidate) ? forwardCandidate : backwardCandidate
    }

    private static func sanitizeRing(_ ring: [Point]) -> [Point] {
        guard ring.isEmpty == false else { return [] }

        var ringPoints = ring
        if let last = ringPoints.last,
           let first = ringPoints.first,
           last.x == first.x,
           last.y == first.y {
            ringPoints.removeLast()
        }

        var filtered: [Point] = []
        filtered.reserveCapacity(ringPoints.count)
        for point in ringPoints {
            if let last = filtered.last,
               last.x == point.x,
               last.y == point.y {
                continue
            }
            if filtered.count >= 2 {
                let beforeLast = filtered[filtered.count - 2]
                if beforeLast.x == point.x, beforeLast.y == point.y {
                    filtered.removeLast()
                    continue
                }
            }
            filtered.append(point)
        }

        if let last = filtered.last,
           let first = filtered.first,
           last.x == first.x,
           last.y == first.y {
            filtered.removeLast()
        }
        return filtered
    }

    private static func packPoint(_ point: Point) -> UInt64 {
        let x = UInt32(bitPattern: point.x)
        let y = UInt32(bitPattern: point.y)
        return (UInt64(x) << 32) | UInt64(y)
    }

    private static func canonicalRotation(_ values: [UInt64]) -> [UInt64] {
        guard values.count > 1 else { return values }

        var best = values
        for start in 1..<values.count {
            var candidate: [UInt64] = []
            candidate.reserveCapacity(values.count)
            candidate.append(contentsOf: values[start...])
            candidate.append(contentsOf: values[..<start])
            if lexicographicallyLess(candidate, best) {
                best = candidate
            }
        }
        return best
    }

    private static func lexicographicallyLess(_ lhs: [UInt64], _ rhs: [UInt64]) -> Bool {
        let count = min(lhs.count, rhs.count)
        for index in 0..<count {
            if lhs[index] != rhs[index] {
                return lhs[index] < rhs[index]
            }
        }
        return lhs.count < rhs.count
    }
}

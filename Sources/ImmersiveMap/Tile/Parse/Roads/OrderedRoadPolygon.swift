// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A polygon of the separate-road path with the keys it sorts by: the
/// unification stage buckets these by structure and pass role and sorts
/// each bucket with `sort`, so a road's casing lies under its fill and a
/// higher class over a lower one whatever order the tile shipped them.
struct OrderedRoadPolygon {
    let polygon: ParsedPolygon
    let styleKey: UInt8
    let structureKind: RoadStructureKind
    let layer: Int
    let classPriority: Int
    let passRole: RoadPassRole
    let sequence: Int

    static func sort(lhs: OrderedRoadPolygon, rhs: OrderedRoadPolygon) -> Bool {
        if lhs.structureKind.rawValue != rhs.structureKind.rawValue {
            return lhs.structureKind.rawValue < rhs.structureKind.rawValue
        }
        if lhs.layer != rhs.layer {
            return lhs.layer < rhs.layer
        }
        if lhs.passRole.rawValue != rhs.passRole.rawValue {
            return lhs.passRole.rawValue < rhs.passRole.rawValue
        }
        if lhs.classPriority != rhs.classPriority {
            return lhs.classPriority < rhs.classPriority
        }
        if lhs.styleKey != rhs.styleKey {
            return lhs.styleKey < rhs.styleKey
        }
        return lhs.sequence < rhs.sequence
    }
}

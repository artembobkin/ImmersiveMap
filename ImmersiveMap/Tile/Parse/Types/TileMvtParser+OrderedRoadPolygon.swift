// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    enum RoadStructureKind: Int {
        case tunnel
        case ground
        case bridge
    }

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
}

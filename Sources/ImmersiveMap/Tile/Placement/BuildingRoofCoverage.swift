// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Where the frame draws buildings: the slots of the building coverage
/// (`BuildingCoveragePlanner`). A label standing on a roof is lifted only
/// inside them, so it rises and settles together with the buildings, and
/// never hangs over ground whose buildings are not drawn (the globe, a zoom
/// coarser than the building grid, beyond the near field, a slot whose
/// tile has not arrived). World copies are not told apart: buildings are a
/// near-field feature and two copies are never both near.
struct BuildingRoofCoverage: Equatable {
    static let none = BuildingRoofCoverage(slots: [])

    private struct Slot: Hashable {
        let x: Int
        let y: Int
        let z: Int
    }

    private let slots: Set<Slot>
    /// The zooms the slots are at, the few a point is looked up at.
    private let zooms: [Int]

    init(placeTilesContext: PlaceTilesContext) {
        self.init(slots: placeTilesContext.tilePlacements.map { placement in
            Slot(x: placement.placeIn.x, y: placement.placeIn.y, z: placement.placeIn.z)
        })
    }

    private init(slots: [Slot]) {
        self.slots = Set(slots)
        self.zooms = Set(slots.map(\.z)).sorted()
    }

    var isEmpty: Bool {
        slots.isEmpty
    }

    /// Whether the buildings are drawn at a point given as a uv in a tile.
    func drawsBuildings(tile: SIMD3<Int32>, uv: SIMD2<Float>) -> Bool {
        guard slots.isEmpty == false else {
            return false
        }
        let tileScale = pow(2.0, -Double(tile.z))
        let mercator = SIMD2<Double>((Double(tile.x) + Double(uv.x)) * tileScale,
                                     (Double(tile.y) + Double(uv.y)) * tileScale)
        for zoom in zooms {
            let tiles = pow(2.0, Double(zoom))
            let slot = Slot(x: Int((mercator.x * tiles).rounded(.down)),
                            y: Int((mercator.y * tiles).rounded(.down)),
                            z: zoom)
            if slots.contains(slot) {
                return true
            }
        }
        return false
    }
}

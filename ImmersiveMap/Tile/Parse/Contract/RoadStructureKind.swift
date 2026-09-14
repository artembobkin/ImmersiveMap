// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Where a road sits in the draw stack. Besides the physical structures,
/// the ground splits in two tiers: the pedestrian network (footways,
/// cycleways, tracks, rail) and, above it, the automobile network. Drawn
/// as one tier, a footway's fill lies over the kerb of the avenue it ends
/// against and a path crossing a street cuts the street's casing; drawn
/// above, the automobile road keeps its edges intact everywhere and the
/// paths read as what they are, the finer network under it.
enum RoadStructureKind: Int, CaseIterable {
    case tunnel
    case ground
    case automobileGround
    case bridge

    /// The bucket of a road, without the tier split: its tagged structure,
    /// or, for a road on the ground, its `layer`, so a street diving under
    /// a bridge draws with the tunnels and a ramp climbing over one with
    /// the bridges.
    init(road: ImmersiveMapRoadFacts) {
        switch road.structure {
        case .tunnel: self = .tunnel
        case .bridge: self = .bridge
        case .ground:
            if road.layer < 0 {
                self = .tunnel
            } else if road.layer > 0 {
                self = .bridge
            } else {
                self = .ground
            }
        }
    }

    /// Where a line draws: on the ground the automobile network draws as
    /// its own tier above the pedestrian one, so a path ending against an
    /// avenue never lies over its kerb. The structure is the schema
    /// reading's, the tier the style's.
    init(road: ImmersiveMapRoadFacts, tier: RoadTier) {
        let bucket = RoadStructureKind(road: road)
        self = bucket == .ground && tier == .automobile ? .automobileGround : bucket
    }
}

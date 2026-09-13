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
}

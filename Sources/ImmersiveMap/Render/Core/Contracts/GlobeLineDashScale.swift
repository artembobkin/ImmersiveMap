// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The dash pattern scale of a coarse tile on the globe. At z0 a tile is a
/// whole hemisphere and its point-locked lines are stubs; a dash pattern
/// shortened as aggressively as the width degenerates would stripe them, and
/// long dashes over a planet view read well, so the pattern keeps at least
/// the z1 proportion everywhere. A function of the source tile zoom only, so
/// it steps with the tile set and never follows the live camera.
enum GlobeLineDashScale {
    static func coarseTileDashScale(sourceTileZoom: Int) -> Float {
        switch sourceTileZoom {
        case ...1: return 0.7
        case 2: return 0.9
        default: return 1.0
        }
    }
}

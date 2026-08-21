// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    enum RoadDecorationKind {
        case none
        case onewayArrow
        case zebraCrossing
        /// A parking area polygon whose detail pass is the synthesized comb
        /// of parking-bay stripes (see `ParkingBayGeometryBuilder`).
        case parkingBays
    }
}

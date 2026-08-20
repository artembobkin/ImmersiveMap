// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct ParseGeometryStyleData {
        let lineWidth: Double
        let lineCapRound: Bool
        let lineJoinRound: Bool
        let dashLength: Double
        let dashGap: Double
        let dashResetsPerSegment: Bool
        /// Tile units the line pulls back from each of its ends that is a
        /// genuine end or a junction (never from a tile-seam cut, which must
        /// run flush to continue in the neighbour). Paint on a road stops
        /// short of where the road ends or meets another, so the last dash
        /// never pokes past the fill and the paint never runs across a
        /// crossing street.
        let endInset: Double
        /// Tile units the line is shifted sideways from the feature's own
        /// polyline, positive to the left of travel. A lane line on a one-way
        /// carriageway is the road's centreline offset to each lane boundary;
        /// the feature's geometry stays where the tiles put it.
        let lateralOffset: Double

        var usesDashPattern: Bool {
            dashLength > 0 && dashGap > 0
        }
        
        init(lineWidth: Double,
             lineCapRound: Bool = false,
             lineJoinRound: Bool = false,
             dashLength: Double = 0,
             dashGap: Double = 0,
             dashResetsPerSegment: Bool = false,
             endInset: Double = 0,
             lateralOffset: Double = 0) {
            self.lineWidth = lineWidth
            self.lineCapRound = lineCapRound
            self.lineJoinRound = lineJoinRound
            self.dashLength = dashLength
            self.dashGap = dashGap
            self.dashResetsPerSegment = dashResetsPerSegment
            self.endInset = endInset
            self.lateralOffset = lateralOffset
        }
    }
}

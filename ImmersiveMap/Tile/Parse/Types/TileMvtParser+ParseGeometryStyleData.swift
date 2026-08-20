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
        /// Tile units of paint next to each junction end that is drawn solid
        /// rather than dashed: a broken lane line goes solid on the approach
        /// to a crossing, which is where overtaking and changing lanes stop.
        /// Zero leaves the paint dashed all the way to the gap.
        let junctionApproachLength: Double
        /// Which side of that split this pass draws. The pass that draws the
        /// approach emits only those two stretches; the pass that draws the
        /// body pulls back past them, so the solid and the dashed paint meet
        /// end to end instead of overlapping.
        let drawsJunctionApproachOnly: Bool

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
             lateralOffset: Double = 0,
             junctionApproachLength: Double = 0,
             drawsJunctionApproachOnly: Bool = false) {
            self.lineWidth = lineWidth
            self.lineCapRound = lineCapRound
            self.lineJoinRound = lineJoinRound
            self.dashLength = dashLength
            self.dashGap = dashGap
            self.dashResetsPerSegment = dashResetsPerSegment
            self.endInset = endInset
            self.lateralOffset = lateralOffset
            self.junctionApproachLength = junctionApproachLength
            self.drawsJunctionApproachOnly = drawsJunctionApproachOnly
        }
    }
}

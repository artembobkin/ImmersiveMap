// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What the tessellator bakes for a line: its width and the shape of its
/// ends, joins and dashes, all in tile units.
public struct LineGeometryStyle: Sendable {
    public let lineWidth: Double
    public let lineCapRound: Bool
    public let lineJoinRound: Bool
    public let dashLength: Double
    public let dashGap: Double
    public let dashResetsPerSegment: Bool

    public var usesDashPattern: Bool {
        dashLength > 0 && dashGap > 0
    }
    
    public init(lineWidth: Double,
         lineCapRound: Bool = false,
         lineJoinRound: Bool = false,
         dashLength: Double = 0,
         dashGap: Double = 0,
         dashResetsPerSegment: Bool = false) {
        self.lineWidth = lineWidth
        self.lineCapRound = lineCapRound
        self.lineJoinRound = lineJoinRound
        self.dashLength = dashLength
        self.dashGap = dashGap
        self.dashResetsPerSegment = dashResetsPerSegment
    }
}

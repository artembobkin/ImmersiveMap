// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MvtTestSupport

extension VectorTileFixture.Feature {
    /// A line of measured paint in the far corner of the tile that draws
    /// nothing (an unmarked crossing is a place to cross, not a figure):
    /// the smallest thing that makes a fixture tile carry the measured
    /// streetscape, so the roads in it draw as carriageways with their
    /// paint, while every count a test makes stays the fixture's own.
    static let streetscapeMarker = VectorTileFixture.Feature(
        id: 9_999,
        geometry: .line(points: [(3900, 3900), (4000, 4000)]),
        properties: ["marking": "crossing_unmarked"])
}

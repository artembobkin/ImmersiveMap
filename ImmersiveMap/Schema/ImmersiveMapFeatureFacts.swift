// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// What one feature is, as the schema reading says: the facts the engine's
/// geometry work needs and the style draws by. A feature is at most one of
/// these things; a feature that is none of them (a ground fill, a border,
/// a river) takes `none`.
public struct ImmersiveMapFeatureFacts: Sendable {
    /// The feature is a road: a centreline, a carriageway surface, a
    /// parking lot, or a line of measured paint.
    public var road: ImmersiveMapRoadFacts?
    /// The feature is a building.
    public var building: ImmersiveMapBuildingExtrusion?
    /// The feature is a point that names a body of water. The parser adds
    /// ocean and sea names of its own at the coarse zooms and skips any the
    /// tile already labels; this is how it recognises those.
    public var namesWaterBody: Bool

    public init(road: ImmersiveMapRoadFacts? = nil,
                building: ImmersiveMapBuildingExtrusion? = nil,
                namesWaterBody: Bool = false) {
        self.road = road
        self.building = building
        self.namesWaterBody = namesWaterBody
    }

    public static let none = ImmersiveMapFeatureFacts()
}

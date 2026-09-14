// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// What one feature is, as the schema reading says: the facts the engine's
/// geometry work needs and the style draws by. A feature that is none of
/// these things (a ground fill, a border, a river) takes `none`.
public struct ImmersiveMapFeatureFacts: Sendable {
    /// The feature is a road: a centreline, a carriageway surface, a
    /// parking lot, or a line of measured paint.
    public var road: ImmersiveMapRoadFacts?
    /// The feature is a building.
    public var building: ImmersiveMapBuildingExtrusion?
    /// What the feature is called, for a feature that can be labelled: a
    /// named point, a road with a name along it, a house number.
    public var label: ImmersiveMapLabelFacts?

    public init(road: ImmersiveMapRoadFacts? = nil,
                building: ImmersiveMapBuildingExtrusion? = nil,
                label: ImmersiveMapLabelFacts? = nil) {
        self.road = road
        self.building = building
        self.label = label
    }

    public static let none = ImmersiveMapFeatureFacts()
}

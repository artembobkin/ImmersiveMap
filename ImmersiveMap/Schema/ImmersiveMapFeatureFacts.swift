// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// What one feature is, as the schema reading says: the facts the engine's
/// geometry work needs and the style draws by. One case per kind of
/// thing, each carrying only that kind's facts; a reader switches over the
/// case and cannot read a label off a building.
public enum ImmersiveMapFeatureFacts: Sendable {
    /// None of the things the facts describe: a ground fill, a border, a
    /// river.
    case none
    /// A road: a centreline, a carriageway surface, a parking lot, or a
    /// line of measured paint. The name along it, where it has one, is
    /// inside (`ImmersiveMapRoadFacts.label`).
    case road(ImmersiveMapRoadFacts)
    /// A building.
    case building(ImmersiveMapBuildingExtrusion)
    /// A point that can be labelled: a place, a POI, a water name, a house
    /// number.
    case labelled(ImmersiveMapLabelFacts)

    public var road: ImmersiveMapRoadFacts? {
        if case .road(let road) = self { return road }
        return nil
    }

    public var building: ImmersiveMapBuildingExtrusion? {
        if case .building(let building) = self { return building }
        return nil
    }

    /// The names of the feature: a labelled point's, or the name along a
    /// road.
    public var label: ImmersiveMapLabelFacts? {
        switch self {
        case .labelled(let label): return label
        case .road(let road): return road.label
        case .none, .building: return nil
        }
    }
}

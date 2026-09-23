// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What a line feature is as a road, beyond how it draws: where it sits
/// (in a tunnel, on the ground, on a bridge, and on which `layer`) and
/// which street it is a piece of. The schema reading
/// (`ImmersiveMapTileSchema`) states these; the engine orders the roads
/// and stitches the pieces of a street from them, and the style draws by
/// them. Neither reads a road tag itself.
///
/// A feature that is not a road (a river, a border) has no road facts at
/// all.
public struct ImmersiveMapRoadFacts: Equatable, Sendable {
    /// The physical structure a road runs on, as the source tags it. A
    /// road that ships only a negative or positive `layer` is on the
    /// ground by this reading, below or above its neighbours: a street
    /// diving under a bridge is not in a tunnel, and is in full view from
    /// above.
    public enum Structure: Sendable {
        case tunnel
        case ground
        case bridge
    }

    public var structure: Structure
    /// The vertical layer among roads of one structure, the source's
    /// `layer`: a bridge over a bridge, a road under a road.
    public var layer: Int
    /// The road's name, empty when it has none. The identity of a street
    /// for counting junctions.
    public var name: String
    /// The key two pieces must share to be drawn as one ribbon with no seam
    /// where they met: the street they belong to plus everything that
    /// changes how a piece draws. Nil for a piece that is never stitched.
    public var stitchingKey: String?
    /// The name laid along the road, nil for a road without one.
    public var label: ImmersiveMapLabelFacts?

    public init(structure: Structure = .ground,
                layer: Int = 0,
                name: String = "",
                stitchingKey: String? = nil,
                label: ImmersiveMapLabelFacts? = nil) {
        self.structure = structure
        self.layer = layer
        self.name = name
        self.stitchingKey = stitchingKey
        self.label = label
    }

    /// A road on the ground with no identity.
    public static let ground = ImmersiveMapRoadFacts()
}

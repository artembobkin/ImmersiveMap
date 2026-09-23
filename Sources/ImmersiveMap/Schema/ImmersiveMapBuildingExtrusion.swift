// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What a polygon feature is as a building, as the schema reading states
/// it (`ImmersiveMapTileSchema`): how tall, on which base, which building
/// it belongs to, and whether it is a part of one.
/// The engine turns this into the extrusion when the style asks for one;
/// it never reads a building tag itself.
public struct ImmersiveMapBuildingExtrusion: Equatable, Sendable {
    /// The height above ground in metres, nil when the tile states none: the
    /// style's fallback height applies, and the building stays flat when that
    /// is zero.
    public var heightMetres: Float?
    /// The height of the base above ground in metres, for a part that starts
    /// above the ground (a tower on a podium). Nil means ground level.
    public var baseHeightMetres: Float?
    /// The building the feature belongs to, when the source names one, so
    /// the outline and the parts of one building are resolved against each
    /// other. Nil means the feature stands for itself.
    public var buildingIdentity: UInt64?
    /// A part of a building rather than its outline.
    public var isPart: Bool
    /// The feature is not raised: the source says so (`extrude=false`,
    /// `hide_3d`) or the building lies underground.
    public var isHidden: Bool

    public init(heightMetres: Float? = nil,
                baseHeightMetres: Float? = nil,
                buildingIdentity: UInt64? = nil,
                isPart: Bool = false,
                isHidden: Bool = false) {
        self.heightMetres = heightMetres
        self.baseHeightMetres = baseHeightMetres
        self.buildingIdentity = buildingIdentity
        self.isPart = isPart
        self.isHidden = isHidden
    }
}

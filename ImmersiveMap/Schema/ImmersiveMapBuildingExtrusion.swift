// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What a polygon feature is as a building, as the schema reading states
/// it (`ImmersiveMapTileSchema`): how tall, on which base, which building
/// it belongs to, whether it is a part of one, and what roof it carries.
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
    /// The shaped roof, nil for a flat lid.
    public var roof: ImmersiveMapRoof?

    public init(heightMetres: Float? = nil,
                baseHeightMetres: Float? = nil,
                buildingIdentity: UInt64? = nil,
                isPart: Bool = false,
                isHidden: Bool = false,
                roof: ImmersiveMapRoof? = nil) {
        self.heightMetres = heightMetres
        self.baseHeightMetres = baseHeightMetres
        self.buildingIdentity = buildingIdentity
        self.isPart = isPart
        self.isHidden = isHidden
        self.roof = roof
    }
}

/// A building's shaped roof, as the schema reading states it.
public struct ImmersiveMapRoof: Equatable, Sendable {
    public var shape: ImmersiveMapRoofShape
    /// The roof's own height in metres, from its base at the walls' top to
    /// its ridge or apex.
    public var heightMetres: Float
    /// Whether the ridge runs along or across the long axis of the
    /// footprint. Nil takes the usual default, along.
    public var orientation: ImmersiveMapRoofOrientation?
    /// A compass azimuth in degrees: the downslope direction the roof faces.
    /// Nil leaves the direction to the footprint.
    public var directionDegrees: Float?

    public init(shape: ImmersiveMapRoofShape,
                heightMetres: Float,
                orientation: ImmersiveMapRoofOrientation? = nil,
                directionDegrees: Float? = nil) {
        self.shape = shape
        self.heightMetres = heightMetres
        self.orientation = orientation
        self.directionDegrees = directionDegrees
    }
}

/// The roof shapes the engine builds. Anything else the tags say is drawn
/// as a flat lid.
public enum ImmersiveMapRoofShape: Sendable {
    case flat
    case gabled
    case hipped
    case pyramid
    case cone
    case dome
    case skillion
}

/// Whether a ridge runs along or across the long axis of the footprint.
public enum ImmersiveMapRoofOrientation: Sendable {
    case along
    case across
}

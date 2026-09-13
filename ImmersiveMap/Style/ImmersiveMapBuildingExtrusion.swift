// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What a polygon feature is as a building, as the style reads it from the
/// tile's schema: how tall, on which base, which building it belongs to,
/// whether it is a part of one, and what roof it carries. The engine turns
/// this into the extrusion; it never reads a building tag itself.
///
/// A schema that carries the OpenStreetMap tags, as the hosted tiles do,
/// gets the reading for free with `openStreetMap(_:)`. A style for another
/// schema states the fields from its own tags.
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

    /// Metres per storey where a building states its levels and not its
    /// height.
    public static let metresPerLevel: Float = 3.2

    /// The reading of the OpenStreetMap tags. Heights come from `height`
    /// and `min_height` or `render_height` and `render_min_height`, either
    /// spelling, or from `building:levels` and
    /// `building:min_level` at `metresPerLevel` each, in metres or feet. The
    /// building identity is `osm_id`, `id` or `building_id`, a part is
    /// `building:part`, and the feature is hidden by `extrude=false`, by
    /// `hide_3d`, or by `underground` and a `location` underground, in a
    /// tunnel or underwater.
    public static func openStreetMap(_ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapBuildingExtrusion {
        let height = properties.metres("height")
            ?? properties.metres("render_height")
            ?? (properties.metres("building:levels") ?? properties.metres("levels")).map { $0 * metresPerLevel }
        let baseHeight = properties.metres("min_height")
            ?? properties.metres("render_min_height")
            ?? (properties.metres("building:min_level") ?? properties.metres("min_level")).map { $0 * metresPerLevel }
        let identity = properties.unsignedInteger("osm_id")
            ?? properties.unsignedInteger("id")
            ?? properties.unsignedInteger("building_id")
        let location = properties.string("location")?.lowercased() ?? ""
        let isUnderground = properties.bool("underground") == true
            || location.contains("underground")
            || location.contains("subterranean")
            || location.contains("tunnel")
            || location.contains("underwater")
        // `extrude` is the Mapbox convention (present, "true"); the
        // OpenMapTiles building layer has no such field. Absent means
        // extruded, and only an explicit false hides.
        let isHidden = properties.bool("extrude") == false
            || properties.bool("hide_3d") == true
            || isUnderground
        return ImmersiveMapBuildingExtrusion(heightMetres: height,
                                             baseHeightMetres: baseHeight,
                                             buildingIdentity: identity,
                                             isPart: properties.bool("building:part") == true,
                                             isHidden: isHidden,
                                             roof: ImmersiveMapRoof.openStreetMap(properties))
    }
}

/// A building's shaped roof, as the style reads it from the tile.
public struct ImmersiveMapRoof: Equatable, Sendable {
    public var shape: ImmersiveMapRoofShape
    /// The roof's own height in metres, from its base at the walls' top to
    /// its ridge or apex.
    public var heightMetres: Float
    /// Whether the ridge runs along or across the long axis of the
    /// footprint. Nil takes the OpenStreetMap default, along.
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

    /// Metres per roof storey where a roof states its levels and not its
    /// height.
    public static let metresPerLevel: Float = 2.5

    /// The reading of the OpenStreetMap roof tags: `roof:shape` (with the
    /// aliases the tagging uses, `gambrel` for gabled, `mansard` for
    /// hipped, `onion` for a dome), `roof:height` or `roof:levels`,
    /// `roof:orientation`, and `roof:direction` as degrees or a compass
    /// point. Nil for a flat or unknown shape and for a roof without height.
    public static func openStreetMap(_ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapRoof? {
        let height = properties.metres("roof:height")
            ?? properties.metres("roof:levels").map { $0 * metresPerLevel }
            ?? 0
        guard height > 0, let shape = shape(properties.string("roof:shape")), shape != .flat else {
            return nil
        }
        return ImmersiveMapRoof(shape: shape,
                                heightMetres: height,
                                orientation: orientation(properties.string("roof:orientation")),
                                directionDegrees: direction(properties))
    }

    private static func shape(_ text: String?) -> ImmersiveMapRoofShape? {
        guard let text else { return nil }
        let normalized = text.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "flat":
            return .flat
        case "gabled", "gable", "gambrel":
            return .gabled
        case "hipped", "hip", "mansard":
            return .hipped
        case "pyramid", "pyramidal":
            return .pyramid
        case "cone", "conical":
            return .cone
        case "dome", "round", "onion", "halfdome":
            return .dome
        case "skillion", "shed", "lean", "leaning":
            return .skillion
        default:
            return nil
        }
    }

    private static func orientation(_ text: String?) -> ImmersiveMapRoofOrientation? {
        switch text?.lowercased() {
        case "along":
            return .along
        case "across":
            return .across
        default:
            return nil
        }
    }

    private static func direction(_ properties: ImmersiveMapFeatureProperties) -> Float? {
        if let degrees = properties.metres("roof:direction") {
            return degrees
        }
        guard let text = properties.string("roof:direction") else { return nil }
        // OSM also allows compass points for roof:direction.
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "n": return 0
        case "nne": return 22.5
        case "ne": return 45
        case "ene": return 67.5
        case "e": return 90
        case "ese": return 112.5
        case "se": return 135
        case "sse": return 157.5
        case "s": return 180
        case "ssw": return 202.5
        case "sw": return 225
        case "wsw": return 247.5
        case "w": return 270
        case "wnw": return 292.5
        case "nw": return 315
        case "nnw": return 337.5
        default: return nil
        }
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

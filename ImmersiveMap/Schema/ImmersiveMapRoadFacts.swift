// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What a line or surface feature is as a road, beyond how it draws: what
/// kind of road thing it is (a centreline, a carriageway surface, a
/// parking lot, measured paint), where it sits (in a tunnel, on the
/// ground, on a bridge, and on which `layer`) and which street it is a
/// piece of. The schema reading (`ImmersiveMapTileSchema`) states these;
/// the engine orders the roads, clips them against the carriageway
/// surfaces and stitches the pieces of a street from them, and the style
/// draws by them. Neither reads a road tag itself.
///
/// A schema that carries the OpenStreetMap tags, as the hosted tiles do,
/// gets the reading of the structure and the street for free with
/// `openStreetMap(_:)`. A feature that is not a road (a river, a border)
/// has no road facts at all.
public struct ImmersiveMapRoadFacts: Equatable, Sendable {
    /// The kind of road thing a feature is.
    public enum Kind: Equatable, Sendable {
        /// A road's own line: the centreline the ribbon is drawn along.
        case centreline
        /// A carriageway surface polygon (a junction area, a stretch of
        /// carriageway): the roadway as an area, which the ribbons that
        /// enter it run under. `reconstructed` is true for a surface
        /// computed from the road graph, false for one mapped by hand.
        case surface(reconstructed: Bool)
        /// A surface parking lot, with its bays parallel to the kerb (a
        /// car length apart) or perpendicular to it.
        case parkingLot(baysParallel: Bool)
        /// Paint the source measured on the ground and shipped as its own
        /// line (a lane line, a stop line, a crossing). It already ends
        /// exactly where it ends on the ground, so the engine's road
        /// machinery leaves it alone: no clipping against carriageway
        /// surfaces, no junction making, no stitching.
        case paint
    }

    public var kind: Kind
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
    /// The vertical layer among roads of one structure, the OpenStreetMap
    /// `layer`: a bridge over a bridge, a road under a road.
    public var layer: Int
    /// The identity of the street the feature is a piece of, as the source
    /// states it: an id assembled from the whole road network before the
    /// tiles were cut, so it holds across a tile boundary. Empty when the
    /// source states none. Two surfaces of one street have the slit between
    /// them paved.
    public var streetIdentity: String
    /// The road's name, empty when it has none. The fallback identity of a
    /// street for counting junctions where the source states no
    /// `streetIdentity`.
    public var name: String
    /// The key two pieces must share to be drawn as one ribbon with no seam
    /// where they met: the street they belong to plus everything that
    /// changes how a piece draws. Nil for a piece that is never stitched.
    public var stitchingKey: String?
    /// The feature is a carriageway surface the engine found to be the roof
    /// of a tunnel (`RoadTunnelSurfaceResolver`): the surface ships no
    /// tunnel tag of its own, only the tunnel's `layer`. Set by the engine,
    /// never by a schema reading, and the one fact the engine adds.
    public var isTunnelRoof: Bool

    public init(kind: Kind = .centreline,
                structure: Structure = .ground,
                layer: Int = 0,
                streetIdentity: String = "",
                name: String = "",
                stitchingKey: String? = nil,
                isTunnelRoof: Bool = false) {
        self.kind = kind
        self.structure = structure
        self.layer = layer
        self.streetIdentity = streetIdentity
        self.name = name
        self.stitchingKey = stitchingKey
        self.isTunnelRoof = isTunnelRoof
    }

    /// A road on the ground with no identity.
    public static let ground = ImmersiveMapRoadFacts()

    /// The feature is in a tunnel: a road that runs underground, or a
    /// surface found to be a tunnel's roof.
    public var isTunnel: Bool {
        structure == .tunnel || isTunnelRoof
    }

    /// A carriageway surface or a parking lot: an area of roadway.
    public var isSurface: Bool {
        switch kind {
        case .surface, .parkingLot:
            return true
        case .centreline, .paint:
            return false
        }
    }

    public var isShippedPaint: Bool {
        kind == .paint
    }

    /// The reading of the OpenStreetMap tags.
    ///
    /// The structure comes from either schema's spelling of tunnel and
    /// bridge (`brunnel`, `structure`, `tunnel`, `bridge`, `underground`, a
    /// `location` underground or elevated) and from the sign of `layer`.
    /// The street identity is `street`, the name `name`. The stitching key
    /// is the street identity where the source states one, with the
    /// attributes that change how a piece draws (`class`, `subclass`,
    /// `brunnel`, `layer`, `oneway`, `width`); without one it is the name
    /// with those attributes and the lane count, both of which are guesses
    /// about the same question the identity answers. `width` is in the key
    /// and the lane count is not where an identity exists, deliberately: a
    /// lane count that differs between pieces is tiler noise the identity
    /// bridges, a stated width that differs is the street actually widening.
    public static func openStreetMap(_ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapRoadFacts {
        let location = properties.string("location")?.lowercased() ?? ""
        let structureValue = properties.string("structure")?.lowercased() ?? ""
        let brunnel = properties.string("brunnel")?.lowercased() ?? ""
        let layer = properties.integer("layer") ?? 0

        let structure: Structure
        if properties.bool("underground") == true
            || properties.bool("tunnel") == true
            || location.contains("underground")
            || location.contains("subterranean")
            || location.contains("tunnel")
            || location.contains("underwater")
            || structureValue == "tunnel"
            || brunnel == "tunnel" {
            structure = .tunnel
        } else if properties.bool("bridge") == true
            || structureValue == "bridge"
            || brunnel == "bridge"
            || location.contains("bridge")
            || location.contains("elevated") {
            structure = .bridge
        } else {
            structure = .ground
        }

        let streetIdentity = properties.text("street")
        let name = properties.string("name") ?? ""
        let stitchingKey: String?
        if streetIdentity.isEmpty == false {
            stitchingKey = "street=" + streetIdentity + ";" + key(of: properties, ["class", "subclass", "brunnel", "layer", "oneway", "width"])
        } else if name.isEmpty == false {
            stitchingKey = key(of: properties, ["name", "class", "subclass", "lanes", "width", "oneway", "brunnel", "layer"])
        } else {
            stitchingKey = nil
        }
        return ImmersiveMapRoadFacts(structure: structure,
                                     layer: layer,
                                     streetIdentity: streetIdentity,
                                     name: name,
                                     stitchingKey: stitchingKey)
    }

    private static func key(of properties: ImmersiveMapFeatureProperties, _ attributes: [String]) -> String {
        var key = ""
        for attribute in attributes {
            key += attribute
            key += "="
            key += properties.text(attribute)
            key += ";"
        }
        return key
    }
}

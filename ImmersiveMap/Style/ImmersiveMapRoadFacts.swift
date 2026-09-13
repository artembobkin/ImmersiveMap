// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What a line or surface feature is as a road, beyond how it draws: where
/// it sits (in a tunnel, on the ground, on a bridge, and on which `layer`)
/// and which street it is a piece of. The style reads these from the
/// tile's schema; the engine orders the roads, clips them against the
/// carriageway surfaces and stitches the pieces of a street from them,
/// and never reads a road tag itself.
///
/// A schema that carries the OpenStreetMap tags, as the hosted tiles do,
/// gets the reading for free with `openStreetMap(_:)`. A feature that is
/// not a road (a river, a border) takes `ground`.
public struct ImmersiveMapRoadFacts: Equatable, Sendable {
    /// The physical structure a road runs on, which decides its place in
    /// the draw order: tunnels under everything, bridges over everything.
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

    public init(structure: Structure = .ground,
                layer: Int = 0,
                streetIdentity: String = "",
                name: String = "",
                stitchingKey: String? = nil) {
        self.structure = structure
        self.layer = layer
        self.streetIdentity = streetIdentity
        self.name = name
        self.stitchingKey = stitchingKey
    }

    /// A feature that is not a road, or a road on the ground with no
    /// identity.
    public static let ground = ImmersiveMapRoadFacts()

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
            || brunnel == "tunnel"
            || layer < 0 {
            structure = .tunnel
        } else if properties.bool("bridge") == true
            || structureValue == "bridge"
            || brunnel == "bridge"
            || location.contains("bridge")
            || location.contains("elevated")
            || layer > 0 {
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

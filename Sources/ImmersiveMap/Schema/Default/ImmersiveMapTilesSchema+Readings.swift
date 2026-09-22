// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The hosted tiles' readings of one feature's tags into the facts. What
/// the tags are called is the hosted schema's contract; the facts they
/// become carry none of it.
extension ImmersiveMapTilesSchema {
    /// A road's structure, layer, street and stitching key.
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
    func road(_ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapRoadFacts {
        let location = properties.string("location")?.lowercased() ?? ""
        let structureValue = properties.string("structure")?.lowercased() ?? ""
        let brunnel = properties.string("brunnel")?.lowercased() ?? ""
        let layer = properties.integer("layer") ?? 0

        let structure: ImmersiveMapRoadFacts.Structure
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

    private func key(of properties: ImmersiveMapFeatureProperties, _ attributes: [String]) -> String {
        var key = ""
        for attribute in attributes {
            key += attribute
            key += "="
            key += properties.text(attribute)
            key += ";"
        }
        return key
    }

    /// Metres per storey where a building states its levels and not its
    /// height.
    static let metresPerBuildingLevel: Float = 3.2

    /// A building's heights, identity and roof. Heights come from `height`
    /// and `min_height` or `render_height` and `render_min_height`, either
    /// spelling, or from `building:levels` and
    /// `building:min_level` at `metresPerBuildingLevel` each, in metres or feet. The
    /// building identity is `osm_id`, `id` or `building_id`, a part is
    /// `building:part`, and the feature is hidden by `extrude=false`, by
    /// `hide_3d`, or by `underground` and a `location` underground, in a
    /// tunnel or underwater.
    func building(_ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapBuildingExtrusion {
        let height = properties.metres("height")
            ?? properties.metres("render_height")
            ?? (properties.metres("building:levels") ?? properties.metres("levels")).map { $0 * Self.metresPerBuildingLevel }
        let baseHeight = properties.metres("min_height")
            ?? properties.metres("render_min_height")
            ?? (properties.metres("building:min_level") ?? properties.metres("min_level")).map { $0 * Self.metresPerBuildingLevel }
        let identity = properties.unsignedInteger("osm_id")
            ?? properties.unsignedInteger("id")
            ?? properties.unsignedInteger("building_id")
        let location = properties.string("location")?.lowercased() ?? ""
        let isUnderground = properties.bool("underground") == true
            || location.contains("underground")
            || location.contains("subterranean")
            || location.contains("tunnel")
            || location.contains("underwater")
        // `extrude` is a convention some sources follow (present, "true");
        // the hosted tiles' building layer has no such field. Absent means
        // extruded, and only an explicit false hides.
        let isHidden = properties.bool("extrude") == false
            || properties.bool("hide_3d") == true
            || isUnderground
        return ImmersiveMapBuildingExtrusion(heightMetres: height,
                                             baseHeightMetres: baseHeight,
                                             buildingIdentity: identity,
                                             isPart: properties.bool("building:part") == true,
                                             isHidden: isHidden,
                                             roof: roof(properties))
    }

    /// Metres per roof storey where a roof states its levels and not its
    /// height.
    static let metresPerRoofLevel: Float = 2.5

    /// A building's shaped roof: `roof:shape` (with the
    /// aliases the tagging uses, `gambrel` for gabled, `mansard` for
    /// hipped, `onion` for a dome), `roof:height` or `roof:levels`,
    /// `roof:orientation`, and `roof:direction` as degrees or a compass
    /// point. Nil for a flat or unknown shape and for a roof without height.
    func roof(_ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapRoof? {
        let height = properties.metres("roof:height")
            ?? properties.metres("roof:levels").map { $0 * Self.metresPerRoofLevel }
            ?? 0
        guard height > 0, let shape = roofShape(properties.string("roof:shape")), shape != .flat else {
            return nil
        }
        return ImmersiveMapRoof(shape: shape,
                                heightMetres: height,
                                orientation: roofOrientation(properties.string("roof:orientation")),
                                directionDegrees: roofDirection(properties))
    }

    private func roofShape(_ text: String?) -> ImmersiveMapRoofShape? {
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

    private func roofOrientation(_ text: String?) -> ImmersiveMapRoofOrientation? {
        switch text?.lowercased() {
        case "along":
            return .along
        case "across":
            return .across
        default:
            return nil
        }
    }

    private func roofDirection(_ properties: ImmersiveMapFeatureProperties) -> Float? {
        if let degrees = properties.metres("roof:direction") {
            return degrees
        }
        guard let text = properties.string("roof:direction") else { return nil }
        // The tags also allow compass points for roof:direction.
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

    /// A feature's names: `name` for the local name, and `name:xx` or
    /// `name_xx` (the hosted tiles flatten the colon) for the name in
    /// language `xx`. Nil for a feature that carries no name at all.
    func names(_ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapLabelFacts? {
        var name: String?
        var namesByLanguage: [String: String] = [:]
        for (key, value) in properties.values {
            guard key.hasPrefix("name"), let text = value.stringValue, text.isEmpty == false else {
                continue
            }
            if key.count == 4 {
                name = text
            } else if key.count > 5 {
                let separator = key[key.index(key.startIndex, offsetBy: 4)]
                guard separator == ":" || separator == "_" else { continue }
                let code = String(key.dropFirst(5))
                if namesByLanguage[code] == nil {
                    namesByLanguage[code] = text
                }
            }
        }
        guard name != nil || namesByLanguage.isEmpty == false else {
            return nil
        }
        return ImmersiveMapLabelFacts(name: name, namesByLanguage: namesByLanguage)
    }
}

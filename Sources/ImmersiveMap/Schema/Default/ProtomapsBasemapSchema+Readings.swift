// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The Protomaps basemap's readings of one feature's tags into the facts.
/// What the tags are called is the basemap's contract; the facts they
/// become carry none of it.
extension ProtomapsBasemapSchema {
    /// A road's structure, layer, name and stitching key.
    ///
    /// The structure is `is_tunnel` or `is_bridge`, and the layer among
    /// roads of one structure is `layer`. The name is `name`. The stitching
    /// key is the name with the attributes that change how a piece draws
    /// (`kind`, `kind_detail`, `is_link`, `oneway`, `layer`, `is_bridge`,
    /// `is_tunnel`). A route reference is left out on purpose: a `ref` that
    /// changes mid-street is not a drawing change. A road without a name
    /// has no key and is never stitched.
    func road(_ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapRoadFacts {
        let structure: ImmersiveMapRoadFacts.Structure
        if properties.bool("is_tunnel") == true {
            structure = .tunnel
        } else if properties.bool("is_bridge") == true {
            structure = .bridge
        } else {
            structure = .ground
        }
        let name = properties.string("name") ?? ""
        let stitchingKey: String? = name.isEmpty
            ? nil
            : key(of: properties, ["name", "kind", "kind_detail", "is_link", "oneway", "layer", "is_bridge", "is_tunnel"])
        return ImmersiveMapRoadFacts(structure: structure,
                                     layer: properties.integer("layer") ?? 0,
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

    /// A building's heights and whether it is a part. Heights come from
    /// `height` and `min_height`, in metres, which the basemap fills in
    /// from the storey count itself when the source states no height. A
    /// part is `kind=building_part`. The basemap names no building
    /// identity, so every feature stands for itself, and a feature with a
    /// negative `layer` lies underground and is not raised.
    func building(_ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapBuildingExtrusion {
        ImmersiveMapBuildingExtrusion(heightMetres: properties.metres("height"),
                                      baseHeightMetres: properties.metres("min_height"),
                                      buildingIdentity: nil,
                                      isPart: properties.string("kind") == "building_part",
                                      isHidden: (properties.integer("layer") ?? 0) < 0)
    }

    /// A feature's names: `name` for the local name and `name:xx` for the
    /// name in language `xx`. The basemap's other name fields are not
    /// names in a language: `name2`, `name3` and `script*` split a mixed
    /// local name by writing system, and `pgf:name:xx` is a pre-shaped
    /// glyph string for a script the engine does not draw that way. A
    /// regional code (`zh-Hans`) is also filed under its language (`zh`)
    /// where that is free, since the map's language asks by the code before
    /// the dash. Nil for a feature that carries no name at all.
    func names(_ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapLabelFacts? {
        var name: String?
        var namesByLanguage: [String: String] = [:]
        var regionalCodes: [(language: String, code: String)] = []
        for (key, value) in properties.values {
            guard key.hasPrefix("name"), let text = value.stringValue, text.isEmpty == false else {
                continue
            }
            if key.count == 4 {
                name = text
            } else if key.hasPrefix("name:") {
                let code = String(key.dropFirst(5))
                guard code.isEmpty == false else { continue }
                namesByLanguage[code] = text
                if let dash = code.firstIndex(of: "-") {
                    regionalCodes.append((language: String(code[..<dash]), code: code))
                }
            }
        }
        for regional in regionalCodes.sorted(by: { $0.code < $1.code }) where namesByLanguage[regional.language] == nil {
            namesByLanguage[regional.language] = namesByLanguage[regional.code]
        }
        guard name != nil || namesByLanguage.isEmpty == false else {
            return nil
        }
        return ImmersiveMapLabelFacts(name: name, namesByLanguage: namesByLanguage)
    }
}

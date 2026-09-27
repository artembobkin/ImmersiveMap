// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The Protomaps basemap's readings of one feature's tags into the facts.
/// What the tags are called is the basemap's contract; the facts they
/// become carry none of it.
extension ProtomapsBasemapSchema {
    /// A road's structure, layer, name, label, routes and stitching key.
    ///
    /// The structure is `is_tunnel` or `is_bridge`, and the layer among
    /// roads of one structure is `layer`. The label is the name in every
    /// language, and nothing else: the route numbers are the routes, which
    /// the style draws on their signs. The routes are the basemap's
    /// `network_N` and `shield_text_N` pairs (`e-road` and `E22`,
    /// `ru:national` and `М-9`), and for a road in no route relation the
    /// `ref` alone, every number of it a route of no network. The name, the
    /// road's identity for counting junctions, is `name`, or the route
    /// reference for a road that has only a number. The stitching key is
    /// the name with the attributes that change how a piece draws (`kind`,
    /// `kind_detail`, `is_link`, `oneway`, `layer`, `is_bridge`,
    /// `is_tunnel`). A reference is left out of the key for a named road on
    /// purpose: a `ref` that changes mid-street is not a drawing change. A
    /// road with neither has no key and is never stitched.
    func road(_ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapRoadFacts {
        let structure: ImmersiveMapRoadFacts.Structure
        if properties.bool("is_tunnel") == true {
            structure = .tunnel
        } else if properties.bool("is_bridge") == true {
            structure = .bridge
        } else {
            structure = .ground
        }
        let references = routeReferences(properties)
        let reference = references.isEmpty ? nil : references.joined(separator: " / ")
        let ownName = properties.string("name") ?? ""
        let name = ownName.isEmpty ? (reference ?? "") : ownName
        let drawingAttributes = ["kind", "kind_detail", "is_link", "oneway", "layer", "is_bridge", "is_tunnel"]
        let stitchingKey: String?
        if ownName.isEmpty == false {
            stitchingKey = key(of: properties, ["name"] + drawingAttributes)
        } else if reference != nil {
            stitchingKey = key(of: properties, ["ref"] + drawingAttributes)
        } else {
            stitchingKey = nil
        }
        return ImmersiveMapRoadFacts(structure: structure,
                                     layer: properties.integer("layer") ?? 0,
                                     name: name,
                                     stitchingKey: stitchingKey,
                                     label: names(properties),
                                     routes: routes(properties, references: references))
    }

    /// The basemap names at most this many routes on one road
    /// (`network_1` to `network_6`).
    private static let routeSlotCount = 6

    /// A road's routes: the pairs of `network_N` and `shield_text_N` in
    /// their order, a slot with no sign text skipped (the basemap lists
    /// the railway and ferry networks a road belongs to there too, with no
    /// text). A road the basemap ships no pair for, but which states its
    /// numbers in `ref`, has one route of no network per number.
    private func routes(_ properties: ImmersiveMapFeatureProperties,
                        references: [String]) -> [ImmersiveMapRouteFacts] {
        var routes: [ImmersiveMapRouteFacts] = []
        for slot in 1...Self.routeSlotCount {
            guard let text = trimmed(properties.string("shield_text_\(slot)")) else {
                continue
            }
            routes.append(ImmersiveMapRouteFacts(network: trimmed(properties.string("network_\(slot)")) ?? "",
                                                 text: text))
        }
        if routes.isEmpty, let text = trimmed(properties.string("shield_text")) {
            routes.append(ImmersiveMapRouteFacts(network: trimmed(properties.string("network")) ?? "",
                                                 text: text))
        }
        if routes.isEmpty {
            routes = references.map { ImmersiveMapRouteFacts(text: $0) }
        }
        return routes
    }

    /// A road's route references as the basemap's `ref` states them, the
    /// several routes of one road (`M10;E105`) apart. Empty for a road
    /// without one.
    private func routeReferences(_ properties: ImmersiveMapFeatureProperties) -> [String] {
        guard let ref = properties.string("ref") else {
            return []
        }
        return ref.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
    }

    private func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), text.isEmpty == false else {
            return nil
        }
        return text
    }

    /// An address point's house number, `addr_housenumber`, as a label.
    /// Nil for a point without one.
    func houseNumber(_ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapLabelFacts? {
        guard let number = properties.string("addr_housenumber")?.trimmingCharacters(in: .whitespaces),
              number.isEmpty == false else {
            return nil
        }
        return ImmersiveMapLabelFacts(name: number)
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

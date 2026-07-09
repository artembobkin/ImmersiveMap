// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  PoiSpriteResolver.swift
//  ImmersiveMap
//

import Foundation

struct PoiSpriteResolver {
    func resolve(attributes: [String: VectorTile_Tile.Value], layerName: String) -> PoiSpriteIcon? {
        // `poi_label` is the Mapbox POI layer; `poi` is the OpenMapTiles one. Both
        // carry class/subclass fields the mapping below understands.
        let normalizedLayer = layerName.lowercased()
        guard normalizedLayer == "poi_label" || normalizedLayer == "poi" else {
            return nil
        }

        let candidates = [
            attributes["maki"]?.stringValue,
            attributes["class"]?.stringValue,
            attributes["type"]?.stringValue,
            attributes["subclass"]?.stringValue
        ]

        for candidate in candidates {
            guard let icon = map(candidate) else { continue }
            return icon
        }

        return nil
    }

    private func map(_ rawValue: String?) -> PoiSpriteIcon? {
        guard let rawValue else {
            return nil
        }

        let normalized = rawValue
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "restaurant", "fast_food", "food_court":
            return .restaurant
        case "cafe", "coffee", "tea", "bakery":
            return .cafe
        case "bar", "pub", "beer", "alcohol":
            return .bar
        case "park", "garden", "national_park", "dog_park":
            return .park
        case "museum", "gallery", "arts", "art_gallery":
            return .museum
        case "hospital", "clinic", "doctor", "dentist", "healthcare":
            return .hospital
        case "school", "college", "university", "kindergarten", "library":
            return .school
        case "airport", "airfield", "aerodrome", "heliport":
            return .airport
        case "stadium", "sport", "sports_centre", "soccer", "basketball", "pitch":
            return .stadium
        case "lodging", "hotel", "hostel", "guest_house":
            return .hotel
        case "shop", "grocery", "supermarket", "mall", "clothing_store", "convenience":
            return .shopping
        case "fuel", "gas_station", "charging_station":
            return .gasStation
        case "pharmacy", "chemist":
            return .pharmacy
        case "viewpoint", "attraction", "tourism":
            return .viewpoint
        default:
            return nil
        }
    }
}

// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// Label placement/ranking rules for the OpenMapTiles schema. Point-label layers
/// are `place`, `water_name`, `poi`, `mountain_peak`, `aerodrome_label` and
/// `housenumber`; road labels ride the `transportation_name` geometry and are
/// handled by the style, not here.
struct OpenMapTilesVectorTileLabelProviderProfile: VectorTileLabelProviderProfile {
    private let lowZoomOverviewMaximumTileZoom = 4
    private let poiMinimumZoom = 13

    let providerID = "openmaptiles"
    let languagePreferences: VectorTileLabelLanguagePreferences

    init(settings: ImmersiveMapSettings) {
        self.languagePreferences = VectorTileLabelLanguagePreferences.from(
            settingsLanguage: settings.labels.language,
            fallbackPolicy: settings.labels.fallbackPolicy
        )
    }

    // Lower value == more important. OpenMapTiles `rank` is 1-based (1 = biggest).
    func sortKey(properties: [String: VectorTile_Tile.Value]) -> Int {
        if let rank = parseIntValue(properties["rank"]) {
            return rank
        }
        // Capitals and populous places float up when rank is absent.
        if isCapital(properties) {
            return 2
        }
        if let population = population(properties), population > 0 {
            return max(1, 1_000 - min(800, Int(log10(Double(population)) * 100.0)))
        }
        return 1_000
    }

    func collisionRank(layerName: String, sortKey: Int) -> Int {
        switch layerName.lowercased() {
        case "place":
            return sortKey
        case "water_name":
            return 20_000 + sortKey
        case "mountain_peak", "aerodrome_label":
            return 40_000 + sortKey
        case "poi":
            return 50_000 + sortKey
        default:
            return sortKey
        }
    }

    func includesBasePointLabel(layerName: String,
                                properties: [String: VectorTile_Tile.Value],
                                tileZoom: Int,
                                sortKey: Int) -> Bool {
        let layer = layerName.lowercased()
        if layer == "housenumber" {
            return true
        }
        guard hasName(properties) else {
            return false
        }
        switch layer {
        case "place":
            return includesPlaceLabel(properties: properties, tileZoom: tileZoom)
        case "water_name":
            return tileZoom > lowZoomOverviewMaximumTileZoom || isOceanOrSea(properties)
        case "mountain_peak", "aerodrome_label":
            return true
        case "poi":
            return tileZoom >= poiMinimumZoom
        default:
            return false
        }
    }

    func identity(feature: VectorTileLabelFeature, text: String, kind: String) -> VectorTileLabelIdentity {
        if let featureID = feature.featureID {
            return .providerFeature(providerID: providerID,
                                    layerName: feature.layerName,
                                    featureID: featureID)
        }
        return .tileLocal(tile: feature.tile,
                          layerName: feature.layerName,
                          text: text,
                          anchor: feature.anchor)
    }

    func normalizedKind(layerName: String, properties: [String: VectorTile_Tile.Value]) -> String {
        [layerName, properties["class"]?.stringValue, properties["subclass"]?.stringValue]
            .compactMap { value in
                guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      normalized.isEmpty == false else {
                    return nil
                }
                return normalized
            }
            .joined(separator: ":")
    }

    func isHouseNumberLayer(_ layerName: String) -> Bool {
        layerName.lowercased() == "housenumber"
    }

    private func includesPlaceLabel(properties: [String: VectorTile_Tile.Value], tileZoom: Int) -> Bool {
        let cls = properties["class"]?.stringValue.lowercased()
        // Continents/countries/oceans dominate the very low zooms.
        if tileZoom <= 2 {
            return cls == "continent" || cls == "country" || cls == "ocean"
        }
        // z3: only countries, major cities and capitals - drop the dense
        // province/state ("... Oblast") labels that otherwise flood this zoom.
        if tileZoom == 3 {
            switch cls {
            case "continent", "country", "city":
                return true
            default:
                return isCapital(properties)
            }
        }
        if tileZoom <= lowZoomOverviewMaximumTileZoom {
            switch cls {
            case "continent", "country", "state", "province", "city":
                return true
            default:
                return isCapital(properties)
            }
        }
        return true
    }

    private func isOceanOrSea(_ properties: [String: VectorTile_Tile.Value]) -> Bool {
        switch properties["class"]?.stringValue.lowercased() {
        case "ocean", "sea":
            return true
        default:
            return false
        }
    }

    private func isCapital(_ properties: [String: VectorTile_Tile.Value]) -> Bool {
        // OpenMapTiles `capital` = 2 (national), 3/4 (regional) when present.
        if let capital = parseIntValue(properties["capital"]), capital > 0 {
            return true
        }
        return false
    }

    private func hasName(_ properties: [String: VectorTile_Tile.Value]) -> Bool {
        properties["name"]?.stringValue.isEmpty == false
            || properties["name:en"]?.stringValue.isEmpty == false
            || properties["name_en"]?.stringValue.isEmpty == false
    }

    private func population(_ properties: [String: VectorTile_Tile.Value]) -> Int? {
        parseIntValue(properties["population"])
    }

    private func parseIntValue(_ value: VectorTile_Tile.Value?) -> Int? {
        guard let value else {
            return nil
        }
        if value.hasIntValue {
            return Int(value.intValue)
        }
        if value.hasUintValue {
            return Int(value.uintValue)
        }
        if value.hasSintValue {
            return Int(value.sintValue)
        }
        if value.hasDoubleValue {
            return Int(value.doubleValue)
        }
        if value.hasFloatValue {
            return Int(value.floatValue)
        }
        if value.hasStringValue {
            return Int(value.stringValue.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

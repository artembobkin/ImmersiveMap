// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// Label placement/ranking rules for the OpenMapTiles schema. Point-label layers
/// are `place`, `water_name`, `poi`, `mountain_peak`, `aerodrome_label` and
/// `housenumber`; road labels ride the `transportation_name` geometry and are
/// handled by the style, not here.
struct ImmersiveMapTilesVectorTileLabelProviderProfile: VectorTileLabelProviderProfile {
    private let lowZoomOverviewMaximumTileZoom = 4
    private let poiMinimumZoom = 13

    /// OSM street furniture that must never become a label at any zoom:
    /// bicycle racks, waste baskets, gates, building entrances, etc.
    /// Such classes amount to thousands of features per tile and only clutter collisions.
    private static let excludedPoiClasses: Set<String> = [
        "bicycle_parking", "waste_basket", "gate", "entrance", "bench",
        "drinking_water", "toilets", "vending_machine", "recycling"
    ]

    /// Cap on the OpenMapTiles local rank: rank is computed within a ~128px
    /// grid cell of the tile, so the threshold means "no more than N labels per cell".
    /// The tail beyond the cap never even reaches the buffers: in a dense center
    /// that is thousands of features per tile. The number is aligned with the
    /// style's reveal schedule (cell budget quadrupled by overzoom): 64 = 4^3,
    /// i.e. the cap holds exactly what the schedule can show by tile.z + 3.
    private static let maximumPoiRank = 64

    let providerID = "immersivemaptiles"
    let languagePreferences: VectorTileLabelLanguagePreferences

    init(settings: ImmersiveMapSettings) {
        self.languagePreferences = VectorTileLabelLanguagePreferences.from(
            settingsLanguage: settings.labels.language,
            fallbackPolicy: settings.labels.fallbackPolicy
        )
    }

    // Lower value == more important. `rank` is 1-based (1 = biggest) and is
    // the whole contract the tiles follow (the label-priority contract):
    // the tiles bake population and capital status into it at build time, so
    // there is no second signal to reconcile, and a feature without a rank is
    // the least important thing in its layer.
    func sortKey(properties: [String: MvtValue]) -> Int {
        parseIntValue(properties["rank"]) ?? 1_000
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
                                properties: [String: MvtValue],
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
            guard tileZoom >= poiMinimumZoom else {
                return false
            }
            if let poiClass = properties["class"]?.stringValue?.lowercased(),
               Self.excludedPoiClasses.contains(poiClass) {
                return false
            }
            if let rank = parseIntValue(properties["rank"]), rank > Self.maximumPoiRank {
                return false
            }
            return true
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

    func normalizedKind(layerName: String, properties: [String: MvtValue]) -> String {
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

    private func includesPlaceLabel(properties: [String: MvtValue], tileZoom: Int) -> Bool {
        let cls = properties["class"]?.stringValue?.lowercased()
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

    private func isOceanOrSea(_ properties: [String: MvtValue]) -> Bool {
        switch properties["class"]?.stringValue?.lowercased() {
        case "ocean", "sea":
            return true
        default:
            return false
        }
    }

    private func isCapital(_ properties: [String: MvtValue]) -> Bool {
        // OpenMapTiles `capital` = 2 (national), 3/4 (regional) when present.
        if let capital = parseIntValue(properties["capital"]), capital > 0 {
            return true
        }
        return false
    }

    private func hasName(_ properties: [String: MvtValue]) -> Bool {
        properties["name"]?.stringValue?.isEmpty == false
            || properties["name:en"]?.stringValue?.isEmpty == false
            || properties["name_en"]?.stringValue?.isEmpty == false
    }

    private func parseIntValue(_ value: MvtValue?) -> Int? {
        switch value {
        case .int(let number), .sint(let number):
            return Int(number)
        case .uint(let number):
            return Int(number)
        case .double(let number):
            return Int(number)
        case .float(let number):
            return Int(number)
        case .string(let text):
            return Int(text.trimmingCharacters(in: .whitespaces))
        case .bool, .absent, nil:
            return nil
        }
    }
}

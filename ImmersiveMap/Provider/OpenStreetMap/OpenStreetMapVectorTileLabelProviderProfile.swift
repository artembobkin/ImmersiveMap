// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct OpenStreetMapVectorTileLabelProviderProfile: VectorTileLabelProviderProfile {
    private let lowZoomOverviewMaximumTileZoom = 3
    private let lowZoomMajorCityMinimumPopulation = 1_000_000

    let providerID = "openstreetmap"
    let languagePreferences: VectorTileLabelLanguagePreferences

    init(settings: ImmersiveMapSettings) {
        self.languagePreferences = VectorTileLabelLanguagePreferences.from(
            settingsLanguage: settings.labels.language,
            fallbackPolicy: settings.labels.fallbackPolicy
        )
    }

    func sortKey(properties: [String: VectorTile_Tile.Value]) -> Int {
        if let rank = parseIntValue(properties["rank"]) {
            return rank
        }
        if let populationSortKey = populationSortKey(properties: properties) {
            return populationSortKey
        }
        if let wayArea = parseDoubleValue(properties["way_area"]) {
            return max(0, 100_000 - Int(wayArea.squareRoot()))
        }
        return 1_000
    }

    func collisionRank(layerName: String, sortKey: Int) -> Int {
        switch layerName.lowercased() {
        case "place_labels":
            return sortKey
        case "boundary_labels":
            return 20_000 + sortKey
        case "water_polygons_labels", "water_lines_labels":
            return 30_000 + sortKey
        case "pois", "public_transport":
            return 50_000 + sortKey
        default:
            return sortKey
        }
    }

    func includesBasePointLabel(layerName: String,
                                properties: [String: VectorTile_Tile.Value],
                                tileZoom: Int,
                                sortKey: Int) -> Bool {
        guard hasName(properties) else {
            return false
        }
        switch layerName.lowercased() {
        case "boundary_labels":
            return includesBoundaryLabel(properties: properties, tileZoom: tileZoom)
        case "place_labels":
            return includesPlaceLabel(properties: properties, tileZoom: tileZoom)
        case "water_polygons_labels", "water_lines_labels", "pois", "public_transport":
            return tileZoom > lowZoomOverviewMaximumTileZoom
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
        [layerName, properties["kind"]?.stringValue, properties["class"]?.stringValue]
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
        layerName.lowercased() == "addresses"
    }

    private func hasName(_ properties: [String: VectorTile_Tile.Value]) -> Bool {
        properties["name"]?.stringValue.isEmpty == false
            || properties["name_en"]?.stringValue.isEmpty == false
            || properties["name_de"]?.stringValue.isEmpty == false
    }

    private func includesBoundaryLabel(properties: [String: VectorTile_Tile.Value], tileZoom: Int) -> Bool {
        guard tileZoom <= lowZoomOverviewMaximumTileZoom else {
            return true
        }
        return parseIntValue(properties["admin_level"]) == 2
    }

    private func includesPlaceLabel(properties: [String: VectorTile_Tile.Value], tileZoom: Int) -> Bool {
        guard tileZoom <= lowZoomOverviewMaximumTileZoom else {
            return true
        }
        guard let kind = properties["kind"]?.stringValue.lowercased(),
              ["capital", "state_capital", "city"].contains(kind),
              let population = parseIntValue(properties["population"]) else {
            return false
        }
        return population >= lowZoomMajorCityMinimumPopulation
    }

    private func populationSortKey(properties: [String: VectorTile_Tile.Value]) -> Int? {
        let kind = properties["kind"]?.stringValue.lowercased()
        if kind == "capital" || kind == "state_capital" {
            return 100
        }
        guard let population = population(properties: properties), population > 0 else {
            return nil
        }
        let populationRank = 1_000 - min(800, Int(log10(Double(population)) * 100.0))
        let capitalBoost = isTruthy(properties["capital"]) ? 150 : 0
        return max(0, populationRank - capitalBoost)
    }

    private func population(properties: [String: VectorTile_Tile.Value]) -> Int? {
        for key in ["population", "pop", "pop_max", "population_max"] {
            guard let population = parseIntValue(properties[key]) else {
                continue
            }
            return population
        }
        return nil
    }

    private func isTruthy(_ value: VectorTile_Tile.Value?) -> Bool {
        guard let value else {
            return false
        }
        if value.hasBoolValue {
            return value.boolValue
        }
        if let intValue = parseIntValue(value) {
            return intValue > 0
        }
        if value.hasStringValue {
            switch value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "yes", "true", "y":
                return true
            default:
                return false
            }
        }
        return false
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
            return Int(value.stringValue)
        }
        return nil
    }

    private func parseDoubleValue(_ value: VectorTile_Tile.Value?) -> Double? {
        guard let value else {
            return nil
        }
        if value.hasDoubleValue {
            return value.doubleValue
        }
        if value.hasFloatValue {
            return Double(value.floatValue)
        }
        if value.hasIntValue {
            return Double(value.intValue)
        }
        if value.hasUintValue {
            return Double(value.uintValue)
        }
        if value.hasSintValue {
            return Double(value.sintValue)
        }
        if value.hasStringValue {
            return Double(value.stringValue)
        }
        return nil
    }
}

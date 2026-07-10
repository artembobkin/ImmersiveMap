// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct MapboxVectorTileLabelProviderProfile: VectorTileLabelProviderProfile {
    private static let houseNumberCollisionPriorityOffset = 100_000
    private static let poiCollisionPriorityOffset = 200_000

    let providerID = "mapbox"
    let languagePreferences: VectorTileLabelLanguagePreferences

    private let settings: ImmersiveMapSettings

    init(settings: ImmersiveMapSettings) {
        self.settings = settings
        languagePreferences = VectorTileLabelLanguagePreferences.from(
            settingsLanguage: settings.labels.language,
            fallbackPolicy: settings.labels.fallbackPolicy
        )
    }

    func sortKey(properties: [String: VectorTile_Tile.Value]) -> Int {
        let classValue = properties["class"]?.stringValue
        let typeValue = properties["type"]?.stringValue
        let rankReferenceValue = typeValue ?? classValue

        let rankKeys = ["symbolrank", "sizerank", "filterrank", "rank", "scalerank", "place_rank", "localrank", "labelrank"]
        var baseRank: Int?
        for key in rankKeys {
            if let value = properties[key], let rank = parseIntValue(value) {
                baseRank = rank
                break
            }
        }

        let classRank = labelClassRank(rankReferenceValue)
        let rankValue = baseRank ?? classRank
        let classBias = labelClassBias(rankReferenceValue)
        let popBoost = populationBoost(properties: properties)
        let capitalBoost = isTruthy(properties["capital"]) ? 30 : 0

        return max(0, rankValue * 10 + classBias - popBoost - capitalBoost)
    }

    func collisionRank(layerName: String, sortKey: Int) -> Int {
        let normalizedLayerName = layerName.lowercased()
        if isHouseNumberLayer(normalizedLayerName) {
            return Self.houseNumberCollisionPriorityOffset + sortKey
        }
        if normalizedLayerName == "poi_label" {
            return Self.poiCollisionPriorityOffset + sortKey
        }
        return sortKey
    }

    func includesBasePointLabel(layerName: String,
                                properties: [String: VectorTile_Tile.Value],
                                tileZoom: Int,
                                sortKey: Int) -> Bool {
        let normalizedLayerName = layerName.lowercased()
        let classValue = properties["class"]?.stringValue
        let typeValue = properties["type"]?.stringValue

        if isRoadPointLabelLayer(normalizedLayerName) || isTransitPointLabelLayer(normalizedLayerName) {
            return false
        }

        if isHouseNumberLayer(normalizedLayerName) {
            guard settings.labels.houseNumbers.enabled else {
                return false
            }
            return tileZoom >= settings.labels.houseNumbers.minimumZoom
        }

        if isContinentPointLabel(layerName: normalizedLayerName,
                                 classValue: classValue,
                                 typeValue: typeValue) {
            guard tileZoom <= 2 else {
                return false
            }
            return true
        }

        if isOceanPointLabel(layerName: normalizedLayerName,
                             classValue: classValue,
                             typeValue: typeValue) {
            guard tileZoom <= 2 else {
                return false
            }
            return true
        }

        if hasCapitalPriority(properties: properties) {
            guard tileZoom >= 2,
                  tileZoom <= settings.labels.settlementVisibility.capitalMaximumZoom else {
                return false
            }
            return true
        }

        if normalizedLayerName == "poi_label" {
            if isLandmarkPointLabel(layerName: normalizedLayerName,
                                    classValue: classValue,
                                    typeValue: typeValue) {
                guard tileZoom >= settings.labels.landmarks.minimumZoom else {
                    return false
                }
                return sortKey <= landmarkSortKeyThreshold(for: tileZoom)
            }

            guard tileZoom >= 13 else {
                return false
            }
            return sortKey <= poiSortKeyThreshold(for: tileZoom)
        }

        if isAirportPointLabelLayer(normalizedLayerName) {
            guard tileZoom >= 8 else {
                return false
            }
            return sortKey <= airportSortKeyThreshold(for: tileZoom)
        }

        if isNaturalPointLabel(layerName: normalizedLayerName, classValue: classValue) {
            guard tileZoom >= 9 else {
                return false
            }
            return sortKey <= naturalSortKeyThreshold(for: tileZoom)
        }

        if isLandmarkPointLabel(layerName: normalizedLayerName,
                                classValue: classValue,
                                typeValue: typeValue) {
            guard tileZoom >= settings.labels.landmarks.minimumZoom else {
                return false
            }
            return sortKey <= landmarkSortKeyThreshold(for: tileZoom)
        }

        if isCityPointLabel(classValue: classValue, typeValue: typeValue) {
            guard tileZoom >= 2,
                  tileZoom <= settings.labels.settlementVisibility.cityMaximumZoom else {
                return false
            }
            return sortKey <= citySortKeyThreshold(for: tileZoom)
        }

        if isDistrictPointLabel(classValue: classValue, typeValue: typeValue) {
            guard tileZoom >= 9 else {
                return false
            }
            return sortKey <= districtSortKeyThreshold(for: tileZoom)
        }

        if isSmallSettlementPointLabel(typeValue: typeValue) {
            guard tileZoom >= 9,
                  tileZoom <= settings.labels.settlementVisibility.smallSettlementMaximumZoom else {
                return false
            }
            return sortKey <= smallSettlementSortKeyThreshold(for: tileZoom)
        }

        return true
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
        [layerName, properties["class"]?.stringValue, properties["type"]?.stringValue]
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
        layerName.lowercased() == "housenum_label"
    }

    private func parseBoolValue(_ value: VectorTile_Tile.Value) -> Bool? {
        if value.hasBoolValue {
            return value.boolValue
        }
        if value.hasUintValue {
            return value.uintValue != 0
        }
        if value.hasSintValue {
            return value.sintValue != 0
        }
        if value.hasIntValue {
            return value.intValue != 0
        }
        if value.hasFloatValue {
            return value.floatValue != 0
        }
        if value.hasDoubleValue {
            return value.doubleValue != 0
        }
        if value.hasStringValue {
            let lower = value.stringValue.lowercased()
            if lower == "true" || lower == "yes" || lower == "1" {
                return true
            }
            if lower == "false" || lower == "no" || lower == "0" {
                return false
            }
        }
        return nil
    }

    private func parseIntValue(_ value: VectorTile_Tile.Value) -> Int? {
        if value.hasIntValue {
            return Int(value.intValue)
        }
        if value.hasSintValue {
            return Int(value.sintValue)
        }
        if value.hasUintValue {
            guard value.uintValue <= UInt64(Int.max) else { return nil }
            return Int(value.uintValue)
        }
        if value.hasFloatValue {
            return Int(value.floatValue)
        }
        if value.hasDoubleValue {
            return Int(value.doubleValue)
        }
        if value.hasStringValue {
            return Int(value.stringValue)
        }
        return nil
    }

    private func parseDoubleValue(_ value: VectorTile_Tile.Value) -> Double? {
        if value.hasDoubleValue {
            return value.doubleValue
        }
        if value.hasFloatValue {
            return Double(value.floatValue)
        }
        if value.hasIntValue {
            return Double(value.intValue)
        }
        if value.hasSintValue {
            return Double(value.sintValue)
        }
        if value.hasUintValue {
            return Double(value.uintValue)
        }
        if value.hasStringValue {
            return Double(value.stringValue)
        }
        return nil
    }

    private func isTruthy(_ value: VectorTile_Tile.Value?) -> Bool {
        guard let value = value else { return false }
        return parseBoolValue(value) ?? false
    }

    private func populationBoost(properties: [String: VectorTile_Tile.Value]) -> Int {
        let popKeys = ["population", "pop", "pop_max", "population_max", "pop_min", "population_min"]
        var population = 0.0
        for key in popKeys {
            if let value = properties[key], let pop = parseDoubleValue(value) {
                population = max(population, pop)
            }
        }
        return population > 0.0 ? Int(min(90.0, log10(population) * 10.0)) : 0
    }

    private func labelClassRank(_ classValue: String?) -> Int {
        guard let value = classValue?.lowercased() else {
            return 80
        }
        switch value {
        case "country":
            return 1
        case "state", "province", "region":
            return 5
        case "ocean":
            return 3
        case "sea":
            return 6
        case "settlement":
            return 12
        case "city":
            return 10
        case "town":
            return 20
        case "village":
            return 30
        case "hamlet":
            return 40
        case "settlement_subdivision":
            return 50
        case "suburb":
            return 50
        case "quarter":
            return 55
        case "neighborhood":
            return 60
        case "neighbourhood":
            return 60
        case "locality":
            return 70
        default:
            return 80
        }
    }

    private func labelClassBias(_ classValue: String?) -> Int {
        guard let value = classValue?.lowercased() else {
            return 9
        }
        switch value {
        case "country":
            return 0
        case "state", "province", "region":
            return 1
        case "ocean":
            return 1
        case "sea":
            return 2
        case "settlement":
            return 2
        case "city":
            return 2
        case "town":
            return 3
        case "village":
            return 4
        case "hamlet":
            return 5
        case "settlement_subdivision":
            return 6
        case "suburb":
            return 6
        case "quarter":
            return 6
        case "neighborhood":
            return 7
        case "neighbourhood":
            return 7
        case "locality":
            return 8
        default:
            return 9
        }
    }

    private func hasCapitalPriority(properties: [String: VectorTile_Tile.Value]) -> Bool {
        if let capitalValue = properties["capital"] {
            if let capitalLevel = parseIntValue(capitalValue), capitalLevel > 0 {
                return true
            }
            if isTruthy(capitalValue) {
                return true
            }
        }
        return false
    }

    private func isRoadPointLabelLayer(_ layerName: String) -> Bool {
        layerName == "road_label"
    }

    private func isTransitPointLabelLayer(_ layerName: String) -> Bool {
        layerName.contains("transit")
    }

    private func isAirportPointLabelLayer(_ layerName: String) -> Bool {
        layerName == "airport_label"
    }

    private func isLandmarkPointLabel(layerName: String,
                                      classValue: String?,
                                      typeValue: String?) -> Bool {
        let normalizedValues = [typeValue, classValue].compactMap(normalizeLandmarkValue)
        guard normalizedValues.isEmpty == false else {
            return false
        }

        for value in normalizedValues {
            switch value {
            case "attraction",
                 "airport",
                 "airfield",
                 "heliport",
                 "tower",
                 "watchtower",
                 "bell_tower",
                 "church",
                 "cathedral",
                 "chapel",
                 "monastery",
                 "abbey",
                 "basilica",
                 "temple",
                 "mosque",
                 "synagogue",
                 "shrine",
                 "square",
                 "plaza",
                 "piazza",
                 "park",
                 "national_park",
                 "garden",
                 "cemetery",
                 "landmark",
                 "museum",
                 "monument",
                 "memorial",
                 "station",
                 "railway_station",
                 "university",
                 "college",
                 "hospital",
                 "viewpoint",
                 "tourism",
                 "zoo",
                 "stadium",
                 "castle",
                 "place_of_worship":
                return true
            default:
                continue
            }
        }
        return false
    }

    private func normalizeLandmarkValue(_ value: String?) -> String? {
        value?
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func isContinentPointLabel(layerName: String,
                                       classValue: String?,
                                       typeValue: String?) -> Bool {
        guard layerName == "natural_label" else {
            return false
        }

        let normalizedValues = [typeValue?.lowercased(), classValue?.lowercased()].compactMap { $0 }
        return normalizedValues.contains("continent")
    }

    private func isOceanPointLabel(layerName: String,
                                   classValue: String?,
                                   typeValue: String?) -> Bool {
        guard layerName == "natural_label" else {
            return false
        }

        let normalizedValues = [typeValue?.lowercased(), classValue?.lowercased()].compactMap { $0 }
        return normalizedValues.contains("ocean") || normalizedValues.contains("sea")
    }

    private func isDistrictPointLabel(classValue: String?, typeValue: String?) -> Bool {
        if classValue?.lowercased() == "settlement_subdivision" {
            return true
        }
        guard let value = typeValue?.lowercased() else {
            return false
        }
        switch value {
        case "suburb",
             "quarter",
             "neighborhood",
             "neighbourhood",
             "locality",
             "borough",
             "district":
            return true
        default:
            return false
        }
    }

    private func isCityPointLabel(classValue: String?, typeValue: String?) -> Bool {
        guard let typeValue = typeValue?.lowercased() else {
            return classValue?.lowercased() == "settlement"
        }
        return typeValue == "city"
    }

    private func isNaturalPointLabel(layerName: String, classValue: String?) -> Bool {
        guard layerName == "natural_label" else {
            return false
        }

        switch classValue?.lowercased() {
        case "river",
             "stream",
             "canal",
             "bay",
             "reservoir",
             "water_feature",
             "landform":
            return true
        default:
            return false
        }
    }

    private func isSmallSettlementPointLabel(typeValue: String?) -> Bool {
        guard let value = typeValue?.lowercased() else {
            return false
        }

        switch value {
        case "town",
             "village",
             "hamlet",
             "isolated_dwelling":
            return true
        default:
            return false
        }
    }

    private func landmarkSortKeyThreshold(for tileZoom: Int) -> Int {
        switch tileZoom {
        case 9:
            return 70
        case 10:
            return 90
        case 11:
            return 110
        case 12:
            return 130
        case 13:
            return 150
        case 14:
            return 170
        default:
            return 200
        }
    }

    private func airportSortKeyThreshold(for tileZoom: Int) -> Int {
        switch tileZoom {
        case 8:
            return 55
        case 9:
            return 75
        case 10...11:
            return 95
        default:
            return 115
        }
    }

    private func naturalSortKeyThreshold(for tileZoom: Int) -> Int {
        switch tileZoom {
        case 9:
            return 70
        case 10:
            return 90
        case 11...12:
            return 110
        default:
            return 130
        }
    }

    private func districtSortKeyThreshold(for tileZoom: Int) -> Int {
        switch tileZoom {
        case 9:
            return 170
        case 10:
            return 160
        case 11:
            return 210
        case 12:
            return 245
        case 13:
            return 280
        case 14:
            return 320
        case 15:
            return 360
        default:
            return 400
        }
    }

    private func citySortKeyThreshold(for tileZoom: Int) -> Int {
        switch tileZoom {
        case 2:
            return 80
        case 3:
            return 70
        case 4:
            return 95
        case 5:
            return 100
        case 6:
            return 105
        case 7:
            return 110
        case 8:
            return 115
        case 9:
            return 120
        case 10:
            return 145
        case 11:
            return 185
        case 12:
            return 225
        case 13:
            return 255
        case 14:
            return 285
        case 15:
            return 315
        default:
            return 345
        }
    }

    private func smallSettlementSortKeyThreshold(for tileZoom: Int) -> Int {
        switch tileZoom {
        case 9:
            return 180
        case 10:
            return 180
        case 11:
            return 220
        case 12:
            return 260
        case 13...14:
            return 320
        default:
            return 380
        }
    }

    private func poiSortKeyThreshold(for tileZoom: Int) -> Int {
        switch tileZoom {
        case 13:
            return 60
        case 14:
            return 90
        case 15:
            return 130
        default:
            return 170
        }
    }
}

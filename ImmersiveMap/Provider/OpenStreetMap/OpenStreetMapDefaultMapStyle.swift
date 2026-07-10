// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

final class OpenStreetMapDefaultMapStyle: ImmersiveMapStyle {
    private static let implementationRevision: UInt32 = 4

    private let fallbackKey: UInt8 = 0
    private let maximumOverviewWaterLabelZoom = 6
    private let landcoverMinimumZoom = 10
    private let configuration: OpenStreetMapDefaultMapStyleConfiguration
    private let settings: ImmersiveMapSettings.StyleSettings
    private let mapBaseColors: ImmersiveMapBaseColors
    private let fallbackStyle: FeatureStyle

    init(configuration: OpenStreetMapDefaultMapStyleConfiguration = .osmDefault,
         settings: ImmersiveMapSettings.StyleSettings = ImmersiveMapSettings.default.style) {
        self.configuration = configuration
        self.settings = settings
        self.mapBaseColors = ImmersiveMapBaseColors(settings: settings.baseColors)
        self.fallbackStyle = FeatureStyle(
            key: fallbackKey,
            color: settings.fallbackFeatureColor,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100)
        )
    }

    var preparedTileStyleRevision: UInt32 {
        settings.preparedTileStyleRevision &+ configuration.cacheFingerprint &+ Self.implementationRevision
    }

    func getMapBaseColors() -> ImmersiveMapBaseColors {
        mapBaseColors
    }

    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        let layerName = data.layerName.lowercased()
        let kind = data.properties["kind"]?.stringValue.lowercased()
        let highway = data.properties["highway"]?.stringValue.lowercased()
        let route = data.properties["route"]?.stringValue.lowercased()

        switch layerName {
        case "background":
            return polygon(key: 1, color: configuration.layers.land)
        case "ocean", "water_polygons":
            return polygon(key: 10, color: configuration.layers.water)
        case "land":
            return landcoverStyle(kind: kind, tileZoom: data.tile.z)
        case "sites":
            return polygon(key: 12, color: siteColor(kind: kind))
        case "buildings":
            return polygon(key: 13, color: configuration.features.buildingFillColor)
        case "streets", "bridges":
            return roadStyle(kind: kind ?? highway)
        case "street_polygons":
            return polygon(key: 44, color: configuration.layers.roads.minor)
        case "street_labels":
            return roadLabelStyle(kind: kind ?? highway)
        case "water_lines", "ferries", "aerialways":
            return line(key: 50,
                        color: layerName == "water_lines" ? configuration.layers.water : configuration.layers.roads.path,
                        width: layerName == "water_lines" ? 3.0 : 2.0)
        case "boundaries":
            return line(key: 60,
                        color: configuration.layers.boundary,
                        width: 1.5,
                        dashLength: 8,
                        dashGap: 6)
        case "place_labels":
            return pointLabel(key: 70, appearance: placeAppearance(kind: kind, properties: data.properties))
        case "pois", "public_transport":
            return pointLabel(key: 71, appearance: configuration.labels.poi)
        case "boundary_labels":
            return pointLabel(key: 72, appearance: boundaryAppearance(tileZoom: data.tile.z))
        case "water_polygons_labels", "water_lines_labels":
            return waterLabelStyle(tileZoom: data.tile.z)
        default:
            if route == "ferry" {
                return line(key: 51, color: configuration.layers.water, width: 2.0, dashLength: 6, dashGap: 6)
            }
            return fallbackStyle
        }
    }

    private func siteColor(kind: String?) -> SIMD4<Float> {
        switch kind {
        case "park", "recreation_ground", "playground", "garden":
            return configuration.layers.park
        case "forest", "wood":
            return configuration.layers.forest
        default:
            return configuration.layers.site
        }
    }

    private func landcoverStyle(kind: String?, tileZoom: Int) -> FeatureStyle {
        guard tileZoom >= landcoverMinimumZoom else {
            return fallbackStyle
        }

        switch kind {
        case "forest", "wood":
            return polygon(key: 11, color: configuration.layers.forest)
        default:
            return polygon(key: 11, color: configuration.layers.land)
        }
    }

    private func roadStyle(kind: String?) -> FeatureStyle {
        let role = roadRole(kind: kind)
        let color: SIMD4<Float>
        let width: Double
        let key: UInt8
        switch role {
        case .major:
            key = 40
            color = configuration.layers.roads.major
            width = 12
        case .minor:
            key = 41
            color = configuration.layers.roads.minor
            width = 7
        case .path:
            key = 42
            color = configuration.layers.roads.path
            width = 3
        }
        return FeatureStyle(
            key: key,
            color: color,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: width,
                                                                         lineCapRound: true,
                                                                         lineJoinRound: true),
            lineRenderPasses: [
                LineRenderPass(key: key &+ 80,
                               color: configuration.layers.roads.casing,
                               parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: width + 2,
                                                                                            lineCapRound: true,
                                                                                            lineJoinRound: true),
                               includeRoadLabelPath: false,
                               roadPassRole: .casing),
                LineRenderPass(key: key,
                               color: color,
                               parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: width,
                                                                                            lineCapRound: true,
                                                                                            lineJoinRound: true),
                               includeRoadLabelPath: false)
            ],
            roadClassPriority: role.priority
        )
    }

    private func roadLabelStyle(kind: String?) -> FeatureStyle {
        let role = roadRole(kind: kind)
        return FeatureStyle(
            key: 90,
            color: SIMD4<Float>(0, 0, 0, 0),
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 1),
            includeRoadLabelPath: true,
            roadClassPriority: role.priority,
            roadLabelTextStyle: labelTextStyle(key: 90, appearance: configuration.labels.road)
        )
    }

    private func pointLabel(key: UInt8,
                            appearance: OpenStreetMapDefaultMapStyleConfiguration.LabelAppearance) -> FeatureStyle {
        FeatureStyle(
            key: key,
            color: SIMD4<Float>(0, 0, 0, 0),
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0),
            labelTextStyle: labelTextStyle(key: Int(key), appearance: appearance)
        )
    }

    private func waterLabelStyle(tileZoom: Int) -> FeatureStyle {
        guard tileZoom > maximumOverviewWaterLabelZoom else {
            return FeatureStyle(
                key: 73,
                color: SIMD4<Float>(0, 0, 0, 0),
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
            )
        }
        return pointLabel(key: 73, appearance: configuration.labels.water)
    }

    private func polygon(key: UInt8, color: SIMD4<Float>) -> FeatureStyle {
        FeatureStyle(
            key: key,
            color: color,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100)
        )
    }

    private func line(key: UInt8,
                      color: SIMD4<Float>,
                      width: Double,
                      dashLength: Double = 0,
                      dashGap: Double = 0) -> FeatureStyle {
        FeatureStyle(
            key: key,
            color: color,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: width,
                                                                         lineCapRound: true,
                                                                         lineJoinRound: true,
                                                                         dashLength: dashLength,
                                                                         dashGap: dashGap)
        )
    }

    private func placeAppearance(kind: String?,
                                 properties: [String: VectorTile_Tile.Value]) -> OpenStreetMapDefaultMapStyleConfiguration.LabelAppearance {
        var appearance = configuration.labels.place
        switch kind {
        case "capital":
            applyCityScale(to: &appearance, sizeDelta: 11, strokeDelta: 1.2)
            appearance.weight = .bold
        case "state_capital", "city":
            let population = population(properties: properties)
            let isCapital = isTruthy(properties["capital"])
            if isCapital || population >= 5_000_000 {
                applyCityScale(to: &appearance, sizeDelta: 11, strokeDelta: 1.2)
            } else if population >= 1_000_000 {
                applyCityScale(to: &appearance, sizeDelta: 8, strokeDelta: 0.8)
            } else if population >= 250_000 {
                applyCityScale(to: &appearance, sizeDelta: 6, strokeDelta: 0.5)
            } else {
                appearance.sizePx += 3
            }
            appearance.weight = .bold
        case "town":
            appearance.sizePx += 1
        case "village", "hamlet":
            appearance.sizePx -= 1
            appearance.weight = .thin
        default:
            break
        }
        return appearance
    }

    private func applyCityScale(to appearance: inout OpenStreetMapDefaultMapStyleConfiguration.LabelAppearance,
                                sizeDelta: Float,
                                strokeDelta: Float) {
        appearance.sizePx += sizeDelta
        appearance.strokeWidthPx += strokeDelta
    }

    private func population(properties: [String: VectorTile_Tile.Value]) -> Int {
        for key in ["population", "pop", "pop_max", "population_max"] {
            guard let value = parseIntValue(properties[key]) else {
                continue
            }
            return value
        }
        return 0
    }

    private func boundaryAppearance(tileZoom: Int) -> OpenStreetMapDefaultMapStyleConfiguration.LabelAppearance {
        var appearance = configuration.labels.boundary
        guard tileZoom <= 3 else {
            return appearance
        }
        appearance.sizePx *= 2
        appearance.strokeWidthPx *= 2
        return appearance
    }

    private func labelTextStyle(key: Int,
                                appearance: OpenStreetMapDefaultMapStyleConfiguration.LabelAppearance) -> LabelTextStyle {
        LabelTextStyle(key: key,
                       fillColor: appearance.fillColor,
                       strokeColor: appearance.strokeColor,
                       strokeWidthPx: appearance.strokeWidthPx,
                       sizePx: appearance.sizePx,
                       weight: appearance.weight)
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

    private func roadRole(kind: String?) -> RoadRole {
        switch kind {
        case "motorway", "trunk", "primary", "secondary":
            return .major
        case "footway", "path", "cycleway", "bridleway", "steps", "track":
            return .path
        default:
            return .minor
        }
    }

    private enum RoadRole {
        case major
        case minor
        case path

        var priority: Int {
            switch self {
            case .major:
                return 30
            case .minor:
                return 20
            case .path:
                return 10
            }
        }
    }
}

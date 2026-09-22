// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The built-in style, for the hosted tiles' schema: the layer and field
/// contract of `immersivemap.dev`
/// (`class`/`subclass`/`brunnel`/`admin_level`/`rank`), over the reading
/// `ImmersiveMapTilesSchema` makes of it.
///
/// This file is the dispatch: the layer switch in `makeStyle`, the
/// road policy every road feature carries, and the builders the rules
/// share.
/// The rules themselves are split by layer family into the extensions
/// next to it: `Ground`, `Buildings`, `Roads`, `RoadWidths`,
/// `Streetscape` and `Labels`. Nothing in them is public: the members are
/// internal only so that the extensions can share them across files.
public struct ImmersiveMapTilesDefaultMapStyle: ImmersiveMapVectorTileStyle {
    static let implementationRevision: UInt32 = 77
    /// Roads opt into the engine's z3->4 camera-zoom fade band, so the major
    /// classes ease in over the globe instead of popping with the z4 tiles.
    let roadLowZoomFadeMask: Float = 2.0
    let landuseMinimumZoom = 6
    let massiveOverviewMaximumZoom = 2
    let globalLandcoverMaximumZoom = 9
    let theme: ImmersiveMapTilesTheme

    /// The land, the water and the ice of the theme, where no tile paints.
    public var baseColors: ImmersiveMapBaseColors {
        theme.baseColors
    }

    public init(theme: ImmersiveMapTilesTheme = .default) {
        self.theme = theme
    }

    /// The palette's fingerprint and the rules' revision: a change to either
    /// re-prepares every tile.
    public var cacheFingerprint: UInt32 {
        theme.cacheFingerprint &+ Self.implementationRevision
    }

    public var styleID: String { "immersivemaptiles" }

    public func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> FeatureStyle {
        makeStyle(data: DetFeatureStyleData(feature))
    }

    public func backgroundStyle(tileZoom: Int) -> FeatureStyle {
        // The full-tile base quad the engine emits per tile. The tiles ship
        // no land polygon, so this is what paints the land; without it the
        // base falls through to the red debug fallback.
        let color = tileZoom <= massiveOverviewMaximumZoom
            ? theme.layers.grass
            : theme.layers.land
        return polygon(key: 1, color: color)
    }

    /// The hosted tiles ship the ocean and sea names in `water_name`, so
    /// the parser adds none of its own.
    public func waterNameStyle(_ kind: WaterNameKind, tileZoom: Int) -> FeatureStyle? {
        nil
    }

    /// From this class priority up a road is part of the automobile network
    /// and draws in the tier above the pedestrian one: service roads sit at
    /// 45 and paths at 35 with rail between.
    static let automobileTierPriority = 45

    /// The road policy every road of this style carries, stated once for
    /// the two branches that produce roads: where it draws and which tier
    /// it belongs to. A style that is no road (a hidden class, a ferry's
    /// plain line) passes through.
    func roadPolicy(applying facts: ImmersiveMapRoadFacts, to style: FeatureStyle) -> FeatureStyle {
        guard case .road(var road) = style else {
            return style
        }
        road.level = Self.roadLevel(facts)
        road.tier = road.classPriority >= Self.automobileTierPriority ? .automobile : .pedestrian
        return .road(road)
    }

    /// Where a road draws: its tagged structure, a roof the engine found,
    /// or, for a road on the ground, its `layer`, so a street diving under
    /// a bridge draws with the tunnels and a ramp climbing over one with
    /// the bridges.
    static func roadLevel(_ facts: ImmersiveMapRoadFacts) -> RoadLevel {
        if facts.isTunnel {
            return .tunnel
        }
        switch facts.structure {
        case .tunnel: return .tunnel
        case .bridge: return .bridge
        case .ground: return facts.layer < 0 ? .tunnel : facts.layer > 0 ? .bridge : .ground
        }
    }

    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        let layer = data.layerName.lowercased()
        let props = data.properties
        let z = data.tile.z
        let cls = props["class"]?.stringValue?.lowercased()
        let subclass = props["subclass"]?.stringValue?.lowercased()

        switch layer {
        case "water":
            return polygon(key: 20, color: theme.layers.water)
        case "waterway":
            return waterwayStyle(cls: cls, props: props)
        case "landcover":
            return landcoverStyle(cls: cls, subclass: subclass, tileZoom: z)
        case "globallandcover":
            return globalLandcoverStyle(cls: cls, tileZoom: z)
        case "landuse":
            return landuseStyle(cls: cls, tileZoom: z)
        case "park":
            return parkLayerStyle(cls: cls, subclass: subclass)
        case "building":
            return buildingStyle(props: props, tileZoom: z)
        case "aeroway":
            return line(key: 28, color: theme.layers.aeroway, width: 4)
        case "transportation", "streetscape":
            // The streetscape (the measured carriageways and road paint)
            // ships in its own layer, which the parser merges into the road
            // layer; a tile with the streetscape and no roads reaches here
            // under its own name and is styled by the same rules.
            let road = data.facts.road ?? .ground
            return roadPolicy(applying: road,
                              to: transportationStyle(cls: cls, props: props,
                                                      road: road,
                                                      tile: data.tile,
                                                      layerCarriesStreetscape: data.layerCarriesStreetscape,
                                                      layerShipsMeasuredCrossings: data.layerShipsMeasuredCrossings))
        case "boundary":
            return boundaryStyle(props: props, tileZoom: z)
        case "transportation_name":
            return roadPolicy(applying: data.facts.road ?? .ground, to: roadLabelStyle(cls: cls))
        case "place":
            guard includesPlaceLabel(props: props, tileZoom: z) else { return hiddenStyle }
            return placeLabelStyle(props: props)
        case "water_name":
            guard includesWaterLabel(props: props, tileZoom: z) else { return hiddenStyle }
            return waterLabelStyle(props: props)
        case "poi":
            guard includesPoiLabel(props: props, tileZoom: z) else { return hiddenStyle }
            return poiLabelStyle(props: props, tileZoom: z)
        case "mountain_peak":
            return pointLabel(key: 74, layer: layer, props: props, appearance: theme.labels.poi)
        case "aerodrome_label":
            return pointLabel(key: 75, layer: layer, props: props, appearance: theme.labels.poi)
        case "housenumber":
            return pointLabel(key: 76, layer: layer, props: props, appearance: houseNumberAppearance())
        default:
            return hiddenStyle
        }
    }

    /// Nothing drawn, for a feature the rules know and decline.
    var hiddenStyle: FeatureStyle {
        .hidden
    }

    func polygon(key: UInt8, color: SIMD4<Float>) -> FeatureStyle {
        .fill(FillStyle(key: key, color: color))
    }

    func line(key: UInt8,
              color: SIMD4<Float>,
              width: Double,
              dashLength: Double = 0,
              dashGap: Double = 0,
              minimumWidthPoints: Float = 0) -> FeatureStyle {
        .line(LineStyle(pass: LinePass(
            key: key,
            color: color,
            minimumWidthPoints: minimumWidthPoints,
            lineGeometry: LineGeometryStyle(lineWidth: width,
                                            lineCapRound: true,
                                            lineJoinRound: true,
                                            dashLength: dashLength,
                                            dashGap: dashGap)
        )))
    }

    func parseIntValue(_ value: MvtValue?) -> Int? {
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

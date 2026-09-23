// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The built-in style, for the Protomaps basemap schema (tiles version 4):
/// the layers `earth`, `landcover`, `landuse`, `water`, `buildings`,
/// `roads`, `boundaries`, `places` and `pois`, each feature told apart by
/// `kind` and `kind_detail`, over the reading `ProtomapsBasemapSchema`
/// makes of it.
///
/// This file is the dispatch: the layer switch in `makeStyle`, the
/// road policy every road feature carries, and the builders the rules
/// share.
/// The rules themselves are split by layer family into the extensions
/// next to it: `Ground`, `Buildings`, `Roads` and `Labels`.
/// Nothing in them is public: the members are
/// internal only so that the extensions can share them across files.
public struct ProtomapsBasemapDefaultMapStyle: ImmersiveMapVectorTileStyle {
    static let implementationRevision: UInt32 = 3
    /// Streets ease in over camera zoom 5 to 6, from the zoom the style first
    /// shows a road (the motorway skeleton on the z5 tiles), instead of
    /// popping with the tiles.
    static let roadZoomFade = ImmersiveMapZoomFade.fadeIn(from: 5, to: 6)
    /// The basemap ships the continuous `landcover` through tile z7 and the
    /// OSM `landuse` in full from z8, with part of the land use already in
    /// the z7 tiles. The engine draws the z7 tiles for camera zoom 7.0 up to
    /// 8.0, so that is where the two families cross-fade: the land cover
    /// fades out and the z7 tiles' land use fades in, and by the time the
    /// z8 tiles take over the land cover is gone and the land use in full.
    static let landcoverMaximumTileZoom = 7
    static let landuseMinimumTileZoom = 7
    static let landuseFullTileZoom = 8
    static let landcoverZoomFade = ImmersiveMapZoomFade.fadeOut(from: 7, to: 8)
    static let landuseHandoverZoomFade = ImmersiveMapZoomFade.fadeIn(from: 7, to: 8)
    /// The basemap ships buildings from z11 as merged blobs with quantized
    /// heights. They only read well next to the street network.
    static let buildingMinimumTileZoom = 13
    let theme: ProtomapsBasemapTheme

    /// The land, the water and the ice of the theme, where no tile paints.
    public var baseColors: ImmersiveMapBaseColors {
        theme.baseColors
    }

    public init(theme: ProtomapsBasemapTheme = .default) {
        self.theme = theme
    }

    /// The palette's fingerprint and the rules' revision: a change to either
    /// re-prepares every tile.
    public var cacheFingerprint: UInt32 {
        theme.cacheFingerprint &+ Self.implementationRevision
    }

    public var styleID: String { "protomaps" }

    public func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> FeatureStyle {
        makeStyle(context: feature)
    }

    /// The full-tile base quad the engine emits per tile, in the land
    /// colour. The basemap ships the land as the `earth` polygon, so the
    /// quad only guards a tile with no earth feature (open ocean, where it
    /// lies under the water fill) and the holes an ocean's islands cut.
    public func backgroundStyle(tileZoom: Int) -> FeatureStyle {
        polygon(key: 1, color: theme.layers.land)
    }

    /// The basemap ships the ocean names as points of `water` from z0, so
    /// the parser adds none of its own.
    public func waterNameStyle(_ kind: WaterNameKind, tileZoom: Int) -> FeatureStyle? {
        nil
    }

    /// From this class priority up a road is part of the automobile network
    /// and draws in the tier above the pedestrian one: service roads sit at
    /// 45 and paths at 35 with rail between.
    static let automobileTierPriority = 45

    /// The road policy every road of this style carries, stated once for
    /// the branches that produce roads: where it draws and which tier
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

    /// Where a road draws: its tagged structure or, for a road on the
    /// ground, its `layer`, so a street diving under a bridge draws with
    /// the tunnels and a ramp climbing over one with the bridges.
    static func roadLevel(_ facts: ImmersiveMapRoadFacts) -> RoadLevel {
        switch facts.structure {
        case .tunnel: return .tunnel
        case .bridge: return .bridge
        case .ground: return facts.layer < 0 ? .tunnel : facts.layer > 0 ? .bridge : .ground
        }
    }

    func makeStyle(context data: ImmersiveMapFeatureStyleContext) -> FeatureStyle {
        let layer = data.layerName.lowercased()
        let props = data.properties.values
        let z = data.tileZoom
        let kind = props["kind"]?.stringValue?.lowercased()
        let kindDetail = props["kind_detail"]?.stringValue?.lowercased()

        switch layer {
        case "earth":
            return polygon(key: 2, color: theme.layers.land)
        case "landcover":
            return landcoverStyle(kind: kind, tileZoom: z)
        case "landuse":
            return landuseStyle(kind: kind, tileZoom: z)
        case "water":
            switch data.geometry {
            case .point:
                guard includesWaterLabel(kind: kind, tileZoom: z) else { return hiddenStyle }
                return waterLabelStyle(kind: kind, props: props)
            case .line:
                return waterwayStyle(kind: kind, kindDetail: kindDetail, props: props)
            case .polygon, .unknown:
                return polygon(key: 20, color: theme.layers.water)
            }
        case "buildings":
            return buildingStyle(facts: data.facts, tileZoom: z)
        case "roads":
            let road = data.facts.road ?? .ground
            return roadPolicy(applying: road,
                              to: roadsStyle(kind: kind,
                                             kindDetail: kindDetail,
                                             props: props,
                                             road: road,
                                             tileZoom: z))
        case "boundaries":
            return boundaryStyle(kind: kind, props: props, tileZoom: z)
        case "places":
            guard includesPlaceLabel(kind: kind, kindDetail: kindDetail, props: props, tileZoom: z) else {
                return hiddenStyle
            }
            return placeLabelStyle(kind: kind, kindDetail: kindDetail, props: props)
        case "pois":
            guard includesPoiLabel(kind: kind, tileZoom: z) else { return hiddenStyle }
            return poiLabelStyle(kind: kind, props: props, tileZoom: z)
        default:
            return hiddenStyle
        }
    }

    /// Nothing drawn, for a feature the rules know and decline.
    var hiddenStyle: FeatureStyle {
        .hidden
    }

    func polygon(key: UInt8,
                 color: SIMD4<Float>,
                 zoomFade: ImmersiveMapZoomFade = .none) -> FeatureStyle {
        .fill(FillStyle(key: key, color: color, zoomFade: zoomFade))
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

    /// A flag as the basemap spells it: a bool, a number or a word.
    func parseBoolValue(_ value: MvtValue?) -> Bool {
        switch value {
        case .bool(let flag):
            return flag
        case .int(let number), .sint(let number):
            return number != 0
        case .uint(let number):
            return number != 0
        case .string(let text):
            let normalized = text.lowercased()
            return normalized == "true" || normalized == "yes" || normalized == "1"
        case .double, .float, .absent, nil:
            return false
        }
    }
}

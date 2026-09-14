// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The built-in style, for the hosted tiles' schema: the layer and field
/// contract of `immersivemap.dev`
/// (`class`/`subclass`/`brunnel`/`admin_level`/`rank`), over the reading
/// `ImmersiveMapTilesSchema` makes of it.
///
/// This file is the dispatch: the layer switch in `resolvedStyle`, the
/// road policy every road feature carries, and the builders the rules
/// share.
/// The rules themselves are split by layer family into the extensions
/// next to it: `Ground`, `Buildings`, `Roads`, `RoadWidths`,
/// `Streetscape` and `Labels`. Nothing in them is public: the members are
/// internal only so that the extensions can share them across files.
public struct ImmersiveMapTilesDefaultMapStyle: ImmersiveMapVectorTileStyle {
    static let implementationRevision: UInt32 = 74
    /// Roads opt into the engine's z3->4 camera-zoom fade band, so the major
    /// classes ease in over the globe instead of popping with the z4 tiles.
    let roadLowZoomFadeMask: Float = 2.0
    let landuseMinimumZoom = 6
    let massiveOverviewMaximumZoom = 2
    let globalLandcoverMaximumZoom = 9
    let configuration: ImmersiveMapTilesDefaultMapStyleConfiguration

    public init(configuration: ImmersiveMapTilesDefaultMapStyleConfiguration = .immersiveMapTilesDefault) {
        self.configuration = configuration
    }

    /// The palette's fingerprint and the rules' revision: a change to either
    /// re-prepares every tile.
    public var cacheFingerprint: UInt32 {
        configuration.cacheFingerprint &+ Self.implementationRevision
    }

    public var styleID: String { "immersivemaptiles" }

    public func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> FeatureStyle {
        makeStyle(data: DetFeatureStyleData(feature))
    }

    public func backgroundStyle(tileZoom: Int) -> FeatureStyle {
        // The full-tile base quad the engine emits per tile. OpenMapTiles
        // has no land polygon, so this is what paints the land; without it
        // the base falls through to the red debug fallback. The street
        // color rides along in every tile: the shader lerps to it
        // continuously in camera zoom, so no tile-zoom boundary flips the
        // ground.
        let overviewColor = tileZoom <= massiveOverviewMaximumZoom
            ? configuration.globalLandcover.grass
            : configuration.globalLandcover.land
        return polygon(key: 1,
                       color: overviewColor,
                       streetColor: configuration.layers.land)
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

    /// From this class priority up a road makes a junction for the paint on
    /// another one: `minor`, the lowest class that is a street rather than a
    /// way onto a plot. A service driveway, a parking aisle and a footway
    /// meeting an avenue leave its markings running, because on the ground
    /// they do.
    static let junctionMakingPriority = 50

    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        let style = resolvedStyle(data: data)
        guard case .road(var road) = style else {
            return style
        }
        let facts = data.facts.road ?? .ground
        road.level = Self.roadLevel(facts)
        road.tier = road.classPriority >= Self.automobileTierPriority ? .automobile : .pedestrian
        road.makesJunctions = facts.isShippedPaint == false
            && road.classPriority >= Self.junctionMakingPriority
        let resolved = FeatureStyle.road(road)
        // Without the streetscape the map is a street map: the roads are
        // strokes by class and nothing is painted on them.
        return data.streetscapeEnabled
            ? resolved
            : resolved.strippingRoadPaint(isShippedPaint: facts.isShippedPaint)
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

    func resolvedStyle(data: DetFeatureStyleData) -> FeatureStyle {
        let layer = data.layerName.lowercased()
        let props = data.properties
        let z = data.tile.z
        let cls = props["class"]?.stringValue?.lowercased()
        let subclass = props["subclass"]?.stringValue?.lowercased()

        switch layer {
        case "water":
            // Same pair for water: the saturated globe blue eases into the
            // pale street blue with the camera, identically in every tile.
            return polygon(key: 20,
                           color: configuration.globalLandcover.water,
                           streetColor: configuration.layers.water)
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
            return line(key: 28, color: configuration.layers.aeroway, width: 4)
        case "transportation", "streetscape":
            // The streetscape (the measured carriageways and road paint) is a
            // second archive the parser folds into the road layer; a tile
            // with the streetscape and no roads reaches here under its own
            // name and is styled by the same rules.
            return transportationStyle(cls: cls, props: props,
                                       road: data.facts.road ?? .ground,
                                       tile: data.tile,
                                       streetscapeEnabled: data.streetscapeEnabled,
                                       layerShipsMeasuredCrossings: data.layerShipsMeasuredCrossings)
        case "boundary":
            return boundaryStyle(props: props, tileZoom: z)
        case "transportation_name":
            return roadLabelStyle(cls: cls)
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
            return pointLabel(key: 74, layer: layer, props: props, appearance: configuration.labels.poi)
        case "aerodrome_label":
            return pointLabel(key: 75, layer: layer, props: props, appearance: configuration.labels.poi)
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

    /// - Parameter far: the footprint fade target (globe and street
    ///   palette) and its strength: where a pixel covers more ground than
    ///   the fill's detail resolves, the colour converges on this tone. nil
    ///   keeps the fill at full contrast at every distance (water, ice).
    func polygon(key: UInt8,
                 color: SIMD4<Float>,
                 streetColor: SIMD4<Float>? = nil,
                 far: FarTone? = nil) -> FeatureStyle {
        // Every ground fill gets the fill-outline antialiasing: its ring
        // edges draw once more as one-pixel lines with alpha by distance to
        // the edge, so a staircase edge stops crawling under camera motion.
        .fill(FillStyle(
            key: key,
            color: color,
            streetColor: streetColor,
            farColor: far.map { SIMD4<Float>($0.color.x, $0.color.y, $0.color.z, $0.strength) },
            farStreetColor: far.map { SIMD4<Float>($0.streetColor.x, $0.streetColor.y, $0.streetColor.z, $0.strength) },
            outlineAntialiasing: true
        ))
    }

    /// The tone a class of ground converges on at distance, one per palette.
    struct FarTone {
        let color: SIMD4<Float>
        let streetColor: SIMD4<Float>
        let strength: Float
    }

    /// The vegetation base is where the land classes meet at distance: a
    /// far pixel covering fields, meadows, woods and villages together is
    /// mostly green, so every one of them fades to that green and the
    /// blotches that were flickering between samples become one plain.
    /// Settlements keep a quarter of their distance, so a city stays a faint
    /// warm patch under its label instead of vanishing.
    var farVegetation: FarTone {
        FarTone(color: configuration.globalLandcover.grass,
                streetColor: configuration.layers.grass,
                strength: 1.0)
    }

    var farSettlement: FarTone {
        FarTone(color: configuration.globalLandcover.grass,
                streetColor: configuration.layers.grass,
                strength: 0.75)
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

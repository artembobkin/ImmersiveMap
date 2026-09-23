// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd
import ImmersiveMap

/// A hand-written vector tile style for the Protomaps basemap schema.
///
/// A style is one function: given a feature (its layer, its zoom, its
/// properties, and what the schema reading says it is), say how to draw it.
/// What a feature is (a road in a tunnel, a building of some height) is the
/// reading's answer, `ProtomapsBasemapSchema` here since the archive is a
/// Protomaps build; this type only says how each looks. The `key` of each
/// style is its identity within a tile and its place in the draw order:
/// ground fills draw in ascending key, so water (20) covers land use (10).
///
/// `cacheFingerprint` matters as much as the drawing: prepared tiles are cached
/// on disk keyed by it, so any change to the rules here must change the number
/// or the map will keep drawing from stale prepared tiles.
struct DemoTileStyle: ImmersiveMapVectorTileStyle {
    /// Bump when any rule below changes.
    let cacheFingerprint: UInt32 = 7

    /// The namespace of the labels' identities, so they never collide with
    /// another style's across tiles.
    let styleID = "demo"

    /// What no tile paints: the ground where nothing has loaded yet, in
    /// this style's land, and the polar caps in its water and its ice.
    var baseColors: ImmersiveMapBaseColors {
        ImmersiveMapBaseColors(map: SIMD4<Float>(0.09, 0.10, 0.12, 1),
                               northCap: SIMD4<Float>(0.10, 0.20, 0.36, 1),
                               southCap: SIMD4<Float>(0.85, 0.88, 0.92, 1))
    }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> FeatureStyle {
        let kind = feature.properties.string("kind") ?? ""
        switch feature.layerName {
        case "water":
            // The layer carries the fills, the rivers and the label points.
            switch feature.geometry {
            case .line:
                return .line(key: 22, color: SIMD4<Float>(0.12, 0.24, 0.42, 1), width: 1.2)
            case .point:
                return .hidden
            case .polygon, .unknown:
                return .polygon(key: 20, color: SIMD4<Float>(0.10, 0.20, 0.36, 1))
            }

        case "landcover", "landuse":
            let color: SIMD4<Float> = switch kind {
            case "wood", "forest": SIMD4<Float>(0.10, 0.18, 0.13, 1)
            case "grass", "grassland", "park", "garden", "scrub": SIMD4<Float>(0.12, 0.20, 0.14, 1)
            case "glacier": SIMD4<Float>(0.30, 0.33, 0.38, 1)
            case "sand", "beach", "barren": SIMD4<Float>(0.26, 0.24, 0.18, 1)
            case "residential", "commercial", "industrial": SIMD4<Float>(0.14, 0.15, 0.17, 1)
            default: SIMD4<Float>(0.13, 0.15, 0.16, 1)
            }
            return .polygon(key: 10, color: color)

        case "buildings":
            // The building's height and base are the schema reading's
            // (`.building` in `feature.facts`); this says it rises, in this
            // colour. `fallbackHeight` applies when the tile states no
            // height.
            return .extrudedPolygon(key: 30,
                                    color: SIMD4<Float>(0.22, 0.24, 0.29, 1),
                                    heightScale: 1.0,
                                    anchorZoom: 16,
                                    fallbackHeight: 8)

        case "roads":
            let detail = feature.properties.string("kind_detail") ?? ""
            let (color, width): (SIMD4<Float>, Float) = switch (kind, detail) {
            case ("highway", _): (SIMD4<Float>(0.65, 0.55, 0.25, 1), 3.0)
            case ("major_road", "trunk"), ("major_road", "primary"): (SIMD4<Float>(0.48, 0.46, 0.30, 1), 2.4)
            case ("major_road", _): (SIMD4<Float>(0.34, 0.35, 0.36, 1), 1.8)
            case ("path", _): (SIMD4<Float>(0.26, 0.26, 0.24, 1), 0.8)
            default: (SIMD4<Float>(0.28, 0.29, 0.31, 1), 1.2)
            }
            // Where the road sits (tunnel, bridge, its layer) is the schema
            // reading's answer, in `feature.facts.road`, the road case of the
            // facts: a tunnel fades to half.
            let inTunnel = feature.facts.road?.structure == .tunnel
            return .line(key: inTunnel ? 39 : 40,
                         color: inTunnel ? SIMD4<Float>(color.x, color.y, color.z, 0.5) : color,
                         width: width)

        case "boundaries":
            // The point-locked line mode: the width is stated in on-screen
            // points and held there at every zoom, the stroke is opaque with
            // butt ends, and the dash pattern is in points too. This is how
            // the built-in style draws country borders; a plain `.line` width
            // lives in tile units and thins into the distance instead.
            return .pointLockedLine(key: 100,
                                    color: SIMD4<Float>(0.42, 0.36, 0.46, 1),
                                    widthPoints: 1.2,
                                    dashLengthPoints: 6,
                                    dashGapPoints: 3)

        case "places":
            // A point label: the text comes from the `name` fields in the
            // map's language; this says how to draw it and how important it
            // is. The basemap ranks places by population, 0 to 17 with 17
            // the biggest, and a place without a rank goes last.
            let populationRank = feature.properties.integer("population_rank")
            return .pointLabel(key: 70,
                               placeLabelStyle(for: feature),
                               rank: populationRank.map { 18 - $0 } ?? 1_000)

        default:
            return .hidden
        }
    }

    private func placeLabelStyle(for feature: ImmersiveMapFeatureStyleContext) -> LabelTextStyle {
        let kind = feature.properties.string("kind") ?? ""
        let isMajor = kind == "country" || feature.properties.string("kind_detail") == "city"
        return LabelTextStyle(
            fillColor: SIMD3<Float>(0.93, 0.94, 0.97),
            strokeColor: SIMD3<Float>(0.03, 0.04, 0.06),
            haloEm: 0.13,
            sizePoints: isMajor ? 16 : 12,
            weight: isMajor ? .bold : .thin)
    }
}

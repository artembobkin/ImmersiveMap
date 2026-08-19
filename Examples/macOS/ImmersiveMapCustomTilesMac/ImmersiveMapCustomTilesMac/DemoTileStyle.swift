// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd
import ImmersiveMap

/// A hand-written vector tile style for the OpenMapTiles schema.
///
/// A style is one function: given a feature (its layer, its zoom, its
/// properties), say how to draw it. Everything the engine knows about the data
/// arrives through `ImmersiveMapFeatureStyleContext`, so this type is where a
/// custom MVT schema turns into geometry.
///
/// `cacheFingerprint` matters as much as the drawing: prepared tiles are cached
/// on disk keyed by it, so any change to the rules here must change the number
/// or the map will keep drawing from stale prepared tiles.
struct DemoTileStyle: ImmersiveMapVectorTileStyle {
    /// Bump when any rule below changes.
    let cacheFingerprint: UInt32 = 4

    /// Colors for the parts of the map that are not features: the tile
    /// background behind everything, the globe backdrop, water and land cover.
    var baseColors: ImmersiveMapSettings.StyleSettings.BaseColors? {
        ImmersiveMapSettings.StyleSettings.BaseColors(
            tileBackground: SIMD4<Float>(0.09, 0.10, 0.12, 1),
            globeBackground: SIMD4<Double>(0.05, 0.06, 0.08, 1),
            water: SIMD4<Float>(0.10, 0.20, 0.36, 1),
            landCover: SIMD4<Float>(0.12, 0.14, 0.16, 1))
    }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapFeatureStyle {
        switch feature.layerName {
        case "water":
            return .polygon(color: SIMD4<Float>(0.10, 0.20, 0.36, 1))

        case "waterway":
            return .line(color: SIMD4<Float>(0.12, 0.24, 0.42, 1), width: 1.2)

        case "landcover":
            let kind = feature.properties.string("class") ?? ""
            let color: SIMD4<Float> = switch kind {
            case "wood", "forest": SIMD4<Float>(0.10, 0.18, 0.13, 1)
            case "grass", "park": SIMD4<Float>(0.12, 0.20, 0.14, 1)
            case "ice", "snow": SIMD4<Float>(0.30, 0.33, 0.38, 1)
            case "sand": SIMD4<Float>(0.26, 0.24, 0.18, 1)
            default: SIMD4<Float>(0.13, 0.15, 0.16, 1)
            }
            return .polygon(color: color)

        case "landuse":
            return .polygon(color: SIMD4<Float>(0.14, 0.15, 0.17, 1))

        case "building":
            // The engine reads the height from the feature and falls back to
            // `fallbackHeight` when the tile carries none.
            return .extrudedPolygon(color: SIMD4<Float>(0.22, 0.24, 0.29, 1),
                                    heightScale: 1.0,
                                    anchorZoom: 16,
                                    fallbackHeight: 8)

        case "transportation":
            let kind = feature.properties.string("class") ?? ""
            let (color, width): (SIMD4<Float>, Float) = switch kind {
            case "motorway": (SIMD4<Float>(0.65, 0.55, 0.25, 1), 3.0)
            case "trunk", "primary": (SIMD4<Float>(0.48, 0.46, 0.30, 1), 2.4)
            case "secondary", "tertiary": (SIMD4<Float>(0.34, 0.35, 0.36, 1), 1.8)
            case "path", "track": (SIMD4<Float>(0.26, 0.26, 0.24, 1), 0.8)
            default: (SIMD4<Float>(0.28, 0.29, 0.31, 1), 1.2)
            }
            return .line(color: color, width: width)

        case "boundary":
            // The point-locked line mode: the width is stated in on-screen
            // points and held there at every zoom, the stroke is opaque with
            // butt ends, and the dash pattern is in points too. This is how
            // the built-in style draws country borders; a plain `.line` width
            // lives in tile units and thins into the distance instead.
            return .pointLockedLine(color: SIMD4<Float>(0.42, 0.36, 0.46, 1),
                                    widthPoints: 1.2,
                                    dashLengthPoints: 6,
                                    dashGapPoints: 3)

        case "place":
            // A point label: the text itself comes from the provider's label
            // profile, this only says how to draw it.
            return .pointLabel(placeLabelStyle(for: feature))

        default:
            return .hidden
        }
    }

    private func placeLabelStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapLabelTextStyle {
        let kind = feature.properties.string("class") ?? ""
        let isMajor = kind == "city" || kind == "country"
        return ImmersiveMapLabelTextStyle(
            fillColor: SIMD3<Float>(0.93, 0.94, 0.97),
            strokeColor: SIMD3<Float>(0.03, 0.04, 0.06),
            haloEm: 0.13,
            sizePoints: isMajor ? 16 : 12,
            weight: isMajor ? .bold : .thin)
    }
}

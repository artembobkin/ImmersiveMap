// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The ground: the land cover and land use fills, the parks, the
/// waterways and the administrative boundaries drawn on it.
extension ImmersiveMapTilesDefaultMapStyle {
    func landcoverStyle(cls: String?, subclass: String?, tileZoom: Int) -> FeatureStyle {
        // The continuous ESA `globallandcover` overlay covers z<=9 (the tile service's
        // overlay-maxzoom). Use it there and suppress the sparser OSM `landcover`,
        // which generalises into tile-filling polygons clipped at tile edges (abrupt
        // per-tile colour jumps). OSM landcover takes over from z10 (street detail).
        //
        // Polygon draw order is by ascending key. Beige landuse
        // (residential/industrial) is lowered to key 9 while all greenery goes
        // above it (11-18), otherwise a park lying inside a residential/block
        // polygon (leisure=park arrives as landcover grass/park) would be
        // covered by beige and look like bare ground. Greenery stays below
        // water (key 20) and roads.
        guard tileZoom >= 10 else {
            return hiddenStyle
        }
        // Each landcover color gets its own key (otherwise the first-wins
        // `styles[key]` collapses all landcover in a tile into the first
        // polygon's color, producing seams at tile borders). All of them sit
        // above the beige landuse (key 9) and below water (20).
        switch cls {
        case "wood", "forest":
            // The overview color is the WorldCover forest these polygons
            // replace at the handover, so they arrive wearing the color the
            // biomes converge on and finish the lerp to the street wood.
            return polygon(key: 11,
                           color: theme.globalLandcover.forest,
                           streetColor: theme.layers.wood,
                           far: farVegetation)
        case "grass":
            // OSM tags countless small courtyards/verges as generic grass; at city
            // zooms suppress those (keep only real green-space subclasses) so they
            // don't tint the whole city.
            if tileZoom >= 13, isGenericGrassSubclass(subclass) {
                return hiddenStyle
            }
            return polygon(key: 12,
                           color: theme.globalLandcover.grass,
                           streetColor: theme.layers.grass,
                           far: farVegetation)
        case "farmland":
            return polygon(key: 13,
                           color: theme.globalLandcover.crop,
                           streetColor: theme.layers.farmland,
                           far: farVegetation)
        case "wetland":
            return polygon(key: 14,
                           color: theme.globalLandcover.wetland,
                           streetColor: theme.layers.wetland,
                           far: farVegetation)
        case "ice":
            return polygon(key: 17,
                           color: theme.globalLandcover.snow,
                           streetColor: theme.layers.ice)
        case "sand":
            return polygon(key: 18,
                           color: theme.globalLandcover.barren,
                           streetColor: theme.layers.sand)
        case "rock":
            // Bare rock = ground color; no separate polygon over the base needed.
            return hiddenStyle
        default:
            // Unknown landcover: blend into the land base rather than paint it green.
            return hiddenStyle
        }
    }

    /// True for generic "grass" that is just urban verge/courtyard clutter (as
    /// opposed to a real park/garden/recreation area worth keeping green).
    func isGenericGrassSubclass(_ subclass: String?) -> Bool {
        switch subclass {
        case "park", "garden", "recreation_ground", "golf_course", "cemetery",
             "meadow", "grassland", "nature_reserve", "dog_park", "pitch", "playground":
            return false
        default:
            return true
        }
    }

    /// ESA WorldCover-derived low-zoom landcover (layer `globallandcover`, merged
    /// into low-zoom tiles by the tile service). The dedicated soft-biome palette
    /// compresses contrast between neighbouring classes while keeping broad forests,
    /// grasslands, crops, wetlands and deserts legible at globe scale. At z0...2 the
    /// vegetation classes collapse into one large mass, with forests only subtly
    /// darker, so source polygon spikes do not dominate the globe. Per-class hole-free
    /// polygons are drawn in a fixed paint order: base land -> biomes -> snow on top.
    /// Keys stay below `water` (20) so oceans/lakes cover landcover.
    func globalLandcoverStyle(cls: String?, tileZoom: Int) -> FeatureStyle {
        let colors = theme.globalLandcover
        let vegetationBase = colors.grass
        // The WorldCover polygons are raster-derived blobs; at overview zooms
        // full-contrast categorical fills read as blotches, so the vegetation
        // classes blend toward one shared tone, fully merged over the globe
        // and releasing gradually to the unmixed palette by z9. Forests keep
        // a quarter of their distance so the big woodlands stay legible, the
        // same proportion the full merge always used. Barren and snow are
        // real geographic edges (deserts, ice caps) and stay unblended.
        let amount = Self.vegetationBlendAmount(tileZoom: tileZoom)
        // Each biome's street color is its OSM street-palette equivalent, so
        // through the handover a WorldCover forest converges on exactly the
        // color the OSM wood polygons that replace it will wear: only the
        // geometry source changes at the swap, never the color language.
        let layers = theme.layers
        switch cls {
        case "land":
            return polygon(key: 2,
                           color: blend(colors.land, toward: vegetationBase, amount: amount),
                           streetColor: layers.land,
                           far: farVegetation)
        case "barren":
            return polygon(key: 3, color: colors.barren, streetColor: layers.sand)
        case "grass", "shrub", "moss":
            return polygon(key: 4, color: colors.grass, streetColor: layers.grass, far: farVegetation)
        case "crop":
            return polygon(key: 5,
                           color: blend(colors.crop, toward: vegetationBase, amount: amount),
                           streetColor: layers.farmland,
                           far: farVegetation)
        case "forest":
            return polygon(key: 6,
                           color: blend(colors.forest, toward: vegetationBase, amount: amount * 0.75),
                           streetColor: layers.wood,
                           far: farVegetation)
        case "wetland", "mangroves":
            return polygon(key: 7,
                           color: blend(colors.wetland, toward: vegetationBase, amount: amount),
                           streetColor: layers.wetland,
                           far: farVegetation)
        case "snow":
            return polygon(key: 8, color: colors.snow, streetColor: layers.ice)
        case "urban":
            // Cities are the one thing a region view exists to show: a soft
            // warm gray, clearly apart from the greens, handing over to the
            // OSM residential beige that replaces it from z10.
            return polygon(key: 10,
                           color: SIMD4<Float>(0.886, 0.871, 0.847, 1.0),
                           streetColor: layers.residential,
                           far: farSettlement)
        default:
            // water: left to the background and water layers.
            return hiddenStyle
        }
    }

    /// How far the vegetation classes blend toward the shared tone at a tile
    /// zoom: 1 is the full massive-overview merge, 0 the unmixed palette.
    static func vegetationBlendAmount(tileZoom: Int) -> Float {
        // The full merge exists for the globe (z0-2), where raster blobs must
        // disappear into one green mass. It releases fast below that: a half
        // blend held into the country zooms kept every class the same green
        // family while leaving the blob edges visible, which read as
        // camouflage blotches over a plain that is two-thirds cropland. By z5
        // the ground and the fields are back to their own near-cream tones and
        // forests are the one green left on them.
        switch tileZoom {
        case ...2: return 1.0
        case 3: return 0.5
        case 4: return 0.3
        case 5: return 0.15
        case 6: return 0.08
        case 7: return 0.04
        default: return 0.0
        }
    }

    func blend(_ base: SIMD4<Float>,
               toward target: SIMD4<Float>,
               amount: Float) -> SIMD4<Float> {
        base + (target - base) * amount
    }

    func landuseStyle(cls: String?, tileZoom: Int) -> FeatureStyle {
        guard tileZoom >= landuseMinimumZoom else {
            return hiddenStyle
        }
        switch cls {
        case "residential", "suburb", "neighbourhood", "quarter", "allotments":
            // Beige residential/block fills go to the very bottom (key 9), below
            // greenery, otherwise they cover parks (landcover) inside residential polygons.
            return polygon(key: 9, color: theme.layers.residential, far: farSettlement)
        case "industrial", "commercial", "retail", "railway", "quarry":
            return polygon(key: 9, color: theme.layers.industrial, far: farSettlement)
        case "cemetery", "grass", "park", "recreation_ground", "garden":
            // One green color for all urban greenery (matches landcover grass)
            // to avoid a two-tone seam where the layers meet.
            return polygon(key: 15, color: theme.layers.grass, far: farVegetation)
        default:
            // Unknown landuse: blend into the land base instead of the red fallback.
            return hiddenStyle
        }
    }

    func waterwayStyle(cls: String?, props: [String: MvtValue]) -> FeatureStyle {
        // Underground/culverted waterways (brunnel=tunnel, e.g. the Neglinnaya
        // under the Alexander Garden) are invisible in reality, so we hide them.
        if props["brunnel"]?.stringValue?.lowercased() == "tunnel" {
            return hiddenStyle
        }
        // The source ships major rivers from z3; without a floor their
        // 2.5-unit width is sub-pixel over a country view and the
        // antialiasing correctly dims them to near-invisibility, so a point
        // floor keeps them readable threads from the first tile they appear
        // in. World growth takes over at street zoom as with roads.
        let width: Double
        let minimumWidthPoints: Float
        switch cls {
        case "river", "canal":
            width = 2.5
            minimumWidthPoints = 0.7
        case "stream":
            width = 1.4
            minimumWidthPoints = 0.5
        default:
            width = 1.0
            minimumWidthPoints = 0.5
        }
        return line(key: 22,
                    color: theme.layers.water,
                    width: width,
                    minimumWidthPoints: minimumWidthPoints)
    }

    /// Below this tile zoom the map is a planet or continent view: regional
    /// (admin 3-4) borders are pure clutter there and stay hidden.
    static let regionalBoundaryMinimumZoom = 4

    func boundaryStyle(props: [String: MvtValue], tileZoom: Int) -> FeatureStyle {
        let adminLevel = parseIntValue(props["admin_level"]) ?? 4
        guard adminLevel <= 4 else {
            return hiddenStyle
        }
        if adminLevel > 2, tileZoom < Self.regionalBoundaryMinimumZoom {
            return hiddenStyle
        }
        // Borders draw through the point-locked line factory (see
        // FeatureStyle.pointLockedLine, which documents the principle they
        // originated): width and dash pattern in layout points, opaque, butt
        // ends, ribbon provisioned to host the width.
        let key: UInt8 = adminLevel <= 2 ? 102 : 100
        // Regional (admin 3-4) borders at country overview zooms: the
        // saturated purple that separates districts at street zooms is the
        // one cold hue in a whole-region frame and reads as scribble there.
        // Until the region zooms the line lightens and turns half
        // transparent; national borders keep their full weight throughout.
        var color = theme.layers.boundary
        if adminLevel > 2, tileZoom <= 6 {
            let softened = color + (SIMD4<Float>(1, 1, 1, color.w) - color) * 0.35
            color = SIMD4<Float>(softened.x, softened.y, softened.z, color.w * 0.6)
        }
        // Borders are drawn as lines only: the point-locked mode fills no
        // areas. Some features (Native American reservations) arrive as
        // polygons; their area must not be filled, otherwise you get solid
        // purple blobs.
        return FeatureStyle.pointLockedLine(
            key: key,
            color: color,
            widthPoints: adminLevel <= 2 ? 1.6 : 1.1,
            dashLengthPoints: 7.0,
            dashGapPoints: 3.5
        )
    }

    /// The OpenMapTiles `park` layer. `national_park`/`nature_reserve` are real green
    /// space; `protected_area` is a broad heritage/administrative designation that
    /// often blankets whole city centres (e.g. Moscow's historic core) - painting it
    /// green makes the entire city read as a park, so it is not drawn as green.
    func parkLayerStyle(cls: String?, subclass: String?) -> FeatureStyle {
        // The park layer covers green areas. Paint explicit parks/gardens/reserves
        // green (the class may be Cyrillic: "национальный_парк",
        // "природно-исторический_парк", ...). Large protected areas without a park
        // attribute (protected_area, "особо охраняемая ...", nature monuments) are
        // hidden to avoid flooding the map with green.
        let kind = "\(cls ?? "") \(subclass ?? "")"
        let greenKeywords = ["park", "парк", "garden", "сад", "reserve", "заповедник", "nature"]
        if greenKeywords.contains(where: { kind.contains($0) }) {
            return polygon(key: 16, color: theme.layers.grass, far: farVegetation)
        }
        return hiddenStyle
    }
}

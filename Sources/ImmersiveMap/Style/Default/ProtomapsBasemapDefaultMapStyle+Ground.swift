// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The ground: the land cover of the overview zooms, the land use of the
/// street zooms, the rivers and the administrative boundaries drawn on it.
///
/// Polygon draw order is by ascending key. The built-up tints
/// (residential, industrial) are lowered to key 9 while all greenery goes
/// above them (11-18), otherwise a park lying inside a residential polygon
/// would be covered and look like bare ground. Greenery stays below water
/// (key 20) and roads. Each colour gets its own key (the first-wins
/// `styles[key]` would otherwise collapse every fill of a tile into the
/// first polygon's colour, producing seams at tile borders).
extension ProtomapsBasemapDefaultMapStyle {
    /// The basemap's `landcover`: the continuous Daylight land cover it
    /// ships through z7, raster-derived blobs whose classes blend toward
    /// one shared tone over the globe and release to the unmixed palette
    /// by the country zooms. Each class wears the colour of what replaces
    /// it from z8 (a landcover forest the wood, farmland the farmland,
    /// barren the sand, a glacier the ice), so the swap changes the
    /// geometry source and never the colour. Grassland and scrub have no
    /// land use counterpart: from z8 open country is the bare `earth`
    /// polygon, so they release to the land tone. Painting them in the
    /// full grass green turned every z7 plain green and the step to z8
    /// into a jump from green to cream.
    ///
    /// The land cover fades out over camera zoom 7 to 8
    /// (`landcoverZoomFade`), while the z7 tiles still serve the view, and
    /// the land use fades in over the same range (`landuseStyle`): the
    /// handover is a cross-fade with the camera, not a step with the tiles.
    func landcoverStyle(kind: String?, tileZoom: Int) -> FeatureStyle {
        guard tileZoom <= Self.landcoverMaximumTileZoom else {
            return hiddenStyle
        }
        let colors = theme.layers
        let fade = Self.landcoverZoomFade
        let vegetationBase = colors.grass
        let amount = Self.vegetationBlendAmount(tileZoom: tileZoom)
        switch kind {
        case "barren":
            return polygon(key: 3, color: colors.sand, zoomFade: fade)
        case "grassland", "scrub":
            return polygon(key: 4,
                           color: blend(colors.land, toward: vegetationBase, amount: amount),
                           zoomFade: fade)
        case "farmland":
            return polygon(key: 5,
                           color: blend(colors.farmland, toward: vegetationBase, amount: amount),
                           zoomFade: fade)
        case "forest":
            return polygon(key: 6,
                           color: blend(colors.wood, toward: vegetationBase, amount: amount * 0.75),
                           zoomFade: fade)
        case "glacier":
            return polygon(key: 8, color: colors.ice, zoomFade: fade)
        case "urban_area":
            // Cities are the one thing a region view exists to show: the
            // residential tone, clearly apart from the greens, the same the
            // street map's residential land use wears from z8.
            return polygon(key: 10, color: colors.residential, zoomFade: fade)
        default:
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

    /// The basemap's `landuse`: the OSM land use and the natural cover of
    /// the street zooms, one kind per feature. In full from tile z8. On the
    /// z7 tiles, which already carry part of it, it fades in over camera
    /// zoom 7 to 8 (`landuseHandoverZoomFade`) as the land cover fades out,
    /// so the z8 tiles take over a frame that already shows it.
    func landuseStyle(kind: String?, tileZoom: Int) -> FeatureStyle {
        guard tileZoom >= Self.landuseMinimumTileZoom else {
            return hiddenStyle
        }
        let colors = theme.layers
        let fade: ImmersiveMapZoomFade = tileZoom < Self.landuseFullTileZoom ? Self.landuseHandoverZoomFade : .none
        switch kind {
        case "residential", "neighbourhood", "farmyard":
            return polygon(key: 9, color: colors.residential, zoomFade: fade)
        case "commercial", "industrial", "railway", "military",
             "hospital", "school", "university", "college":
            // Schools and hospitals are the muted built tone, not a green:
            // their grounds are courtyards and car parks, not parks.
            return polygon(key: 9, color: colors.industrial, zoomFade: fade)
        case "forest", "wood":
            return polygon(key: 11, color: colors.wood, zoomFade: fade)
        case "park", "garden", "grass", "meadow", "recreation_ground", "cemetery",
             "golf_course", "pitch", "playground", "dog_park", "zoo",
             "national_park", "nature_reserve", "scrub":
            // One green for all urban greenery, so no two-tone seam where a
            // park meets the pitch inside it.
            return polygon(key: 12, color: colors.grass, zoomFade: fade)
        case "farmland", "orchard":
            return polygon(key: 13, color: colors.farmland, zoomFade: fade)
        case "wetland":
            return polygon(key: 14, color: colors.wetland, zoomFade: fade)
        case "glacier":
            return polygon(key: 17, color: colors.ice, zoomFade: fade)
        case "sand", "beach":
            return polygon(key: 18, color: colors.sand, zoomFade: fade)
        case "aerodrome", "runway", "taxiway":
            return polygon(key: 19, color: colors.aeroway, zoomFade: fade)
        case "pedestrian", "pier":
            // The basemap ships a bridge's deck (`man_made=bridge`) as a
            // `pedestrian` area, the same kind as a paved square. The deck
            // lies over the river, so it draws above the water, its
            // waterway lines and the ferry routes, in the land tone, under
            // the roads it carries. A square on land in the land tone reads
            // as the ground it is.
            guard tileZoom >= Self.bridgeDeckMinimumTileZoom else {
                return hiddenStyle
            }
            return .fill(FillStyle(key: Self.bridgeDeckKey,
                                   color: colors.land,
                                   drawsAmongGroundLines: true))
        default:
            // A protected area blankets whole city centres, and the rest (a
            // marina, a stadium, an attraction) says nothing a fill should.
            return hiddenStyle
        }
    }

    /// The deck's place among the ground lines: above the waterway lines
    /// (22) and the ferry routes (23), below the aeroway lines and the
    /// borders.
    static let bridgeDeckKey: UInt8 = 24
    /// A deck only reads next to the street network it carries.
    static let bridgeDeckMinimumTileZoom = 13

    /// A river, a canal or a stream: the lines of the `water` layer. The
    /// basemap spells the waterway kind on `kind` for a line and on
    /// `kind_detail` for a body, so both are read.
    func waterwayStyle(kind: String?, kindDetail: String?, props: [String: MvtValue]) -> FeatureStyle {
        // A culverted waterway is invisible in reality.
        if let tunnel = props["tunnel"]?.stringValue?.lowercased(), tunnel.isEmpty == false, tunnel != "no" {
            return hiddenStyle
        }
        // The basemap ships major rivers from z9; without a floor their
        // 2.5-unit width is sub-pixel over a region view and the
        // antialiasing correctly dims them to near-invisibility, so a point
        // floor keeps them readable threads from the first tile they appear
        // in. World growth takes over at street zoom as with roads.
        let width: Double
        let minimumWidthPoints: Float
        switch kindDetail ?? kind {
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
    /// borders are pure clutter there and stay hidden.
    static let regionalBoundaryMinimumZoom = 4

    /// The `boundaries` layer: the country borders at every zoom, the
    /// regions from the regional zoom, and nothing finer. A disputed
    /// border keeps the stroke and takes a short dash.
    func boundaryStyle(kind: String?, props: [String: MvtValue], tileZoom: Int) -> FeatureStyle {
        let isCountry: Bool
        switch kind {
        case "country":
            isCountry = true
        case "region":
            isCountry = false
        default:
            return hiddenStyle
        }
        if isCountry == false, tileZoom < Self.regionalBoundaryMinimumZoom {
            return hiddenStyle
        }
        // Borders draw through the point-locked line factory (see
        // FeatureStyle.pointLockedLine, which documents the principle they
        // originated): width and dash pattern in layout points, opaque, butt
        // ends, ribbon provisioned to host the width.
        let key: UInt8 = isCountry ? 102 : 100
        // Regional borders at country overview zooms: the saturated purple
        // that separates districts at street zooms is the one cold hue in a
        // whole-region frame and reads as scribble there. Until the region
        // zooms the line lightens and turns half transparent; national
        // borders keep their full weight throughout.
        var color = theme.layers.boundary
        if isCountry == false, tileZoom <= 6 {
            let softened = color + (SIMD4<Float>(1, 1, 1, color.w) - color) * 0.35
            color = SIMD4<Float>(softened.x, softened.y, softened.z, color.w * 0.6)
        }
        let disputed = parseBoolValue(props["disputed"])
        // Borders are drawn as lines only: the point-locked mode fills no
        // areas, so a boundary that arrives as a polygon is never a blob.
        return FeatureStyle.pointLockedLine(
            key: key,
            color: color,
            widthPoints: isCountry ? 1.6 : 1.1,
            dashLengthPoints: disputed ? 3.0 : 7.0,
            dashGapPoints: disputed ? 3.0 : 3.5
        )
    }
}

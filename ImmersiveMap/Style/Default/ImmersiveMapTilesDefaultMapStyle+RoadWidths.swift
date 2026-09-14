// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// How wide a road is: the metres a class occupies on the ground, the
/// lanes it carries, the conversion of both into tile units for one tile,
/// and the on-screen strokes of the zooms where a road is a symbol.
extension ImmersiveMapTilesDefaultMapStyle {
    /// The equatorial circumference the Web Mercator tile grid is built on.
    static let equatorialCircumferenceMetres: Double = 40_075_016.686

    /// The canonical tile coordinate space every parsed geometry lives in
    /// (`TileCoordinateSpace.tileExtentDouble`).
    static let tileExtentUnits: Double = 4096

    /// Tile units per ground metre for one tile.
    ///
    /// A road's width is a fact about the ground, so the style states it in
    /// metres and converts here. Web Mercator's scale is a function of
    /// latitude, taken at the tile's own centre, and the tile's zoom sets how
    /// much ground its 4096 units span. Doing the conversion per tile is what
    /// makes a road the same width on screen whichever zoom's tile happens to
    /// serve it: a street drawn from a coarse tile in the distance and the
    /// same street drawn from a native tile underfoot agree, where a width
    /// stated directly in tile units would differ by the zoom ratio between
    /// them.
    static func tileUnitsPerMetre(tile: Tile) -> Double {
        let tilesCount = Double(1 << max(0, tile.z))
        let normalizedY = (Double(tile.y) + 0.5) / tilesCount
        let latitudeRadians = atan(sinh(Double.pi * (1.0 - 2.0 * normalizedY)))
        let groundSpanMetres = equatorialCircumferenceMetres * cos(latitudeRadians) / tilesCount
        guard groundSpanMetres > 0.0001 else {
            return 0
        }
        return tileExtentUnits / groundSpanMetres
    }

    /// Carriageway width in metres, from the lane count the tiles carry.
    ///
    /// `lanes` is per way, so a dual carriageway arrives as two features and
    /// each gets its own width. Where the tag is missing the class states a
    /// typical lane count instead, which is what the width used to be based
    /// on implicitly.
    ///
    /// The lane width is the whole road's width divided by its lanes, which
    /// is more than the painted lane: a street is lanes plus the parking
    /// strip along it, plus the gutter to the kerb. OSM's `lanes` counts the
    /// marked through lanes and nothing else, so a two-lane city street with
    /// cars parked on both sides is around 12 m wide, not 6.5, and a width of
    /// 3.25 m per counted lane drew every such street at half its width.
    /// The carriageway width the tiles state outright, in metres, or nil.
    ///
    /// `width` arrives in decimetres and is measured by the same model that
    /// builds the junction polygons (the street's cross-section, lane by
    /// lane), which is the whole point: a junction polygon inside ribbons of
    /// a DIFFERENT width model floats like a puddle, because its straight
    /// cuts land in the middle of asphalt instead of on the ribbon's edge.
    /// One width model, one geometry.
    func statedWidthMetres(props: [String: MvtValue]) -> Double? {
        guard let decimetres = parseIntValue(props["width"]), decimetres > 0 else {
            return nil
        }
        let metres = Double(decimetres) / 10.0
        // A width outside these bounds is a data accident, not a road.
        guard metres >= 2.0, metres <= 60.0 else { return nil }
        return metres
    }

    func roadWidthMetres(cls: String?, props: [String: MvtValue]) -> Double {
        if let stated = statedWidthMetres(props: props) {
            return stated
        }
        let laneWidthMetres: Double
        switch cls {
        case "motorway", "trunk", "primary":
            laneWidthMetres = 4.0
        case "secondary", "tertiary":
            laneWidthMetres = 4.5
        case "minor":
            laneWidthMetres = 5.0
        case "service":
            laneWidthMetres = 4.0
        default:
            // Footways, tracks and anything unclassified: not a carriageway,
            // so a fixed walkable width rather than a lane count.
            return 2.0
        }
        return Double(roadLaneCount(cls: cls, props: props)) * laneWidthMetres
    }

    /// The lane count a road draws with: the tiles' `lanes` within a sane
    /// range (the tag carries occasional nonsense, and a road hundreds of
    /// metres wide would swamp the frame), else a typical count per class.
    func roadLaneCount(cls: String?, props: [String: MvtValue]) -> Int {
        let defaultLanes: Int
        switch cls {
        case "motorway": defaultLanes = 4
        case "trunk", "primary": defaultLanes = 3
        case "secondary", "tertiary", "minor": defaultLanes = 2
        default: defaultLanes = 1
        }
        return min(max(parseIntValue(props["lanes"]) ?? defaultLanes, 1), 12)
    }

    /// What paint an automobile road carries.
    enum RoadMarkings {
        case none
        /// A two-way street: one dashed line down the middle. The boundaries
        /// inside each direction are not drawn: placing them needs the split
        /// between the directions, and the tiles carry only the total.
        case centreDivider
        /// A one-way carriageway of several lanes: a dashed line on each
        /// boundary between lanes, none in the middle of the road.
        case laneLines(laneCount: Int)
    }

    /// Lateral offsets of every boundary between lanes, in tile units from
    /// the centreline. A road of `laneCount` lanes has `laneCount - 1` of
    /// them, evenly spaced; with an even count one of them is the centre.
    static func laneBoundaryOffsets(width: Double, laneCount: Int) -> [Double] {
        let lanes = max(laneCount, 1)
        guard lanes >= 2 else { return [] }
        let laneWidth = width / Double(lanes)
        return (1..<lanes).map { -width * 0.5 + laneWidth * Double($0) }
    }

    /// The width of a road's carriageway in the tile's own units.
    func roadWidthUnits(cls: String?,
                        props: [String: MvtValue],
                        tile: Tile) -> Double {
        roadWidthMetres(cls: cls, props: props) * Self.tileUnitsPerMetre(tile: tile)
    }

    /// The street map's stroke, the road of a map without the streetscape:
    /// a full width per class in layout points at street zoom, the ladder
    /// every street map draws (a motorway the widest, a service alley a
    /// sliver), and nothing read off the tiles' lane count. It is stated
    /// as a nominal width at tile z16 and converted to this tile's units
    /// world-locked, so the stroke is continuous across the tile levels
    /// that serve it and doubles with each camera zoom past 16, the way a
    /// street map's roads keep growing under a closing camera. Below street
    /// zoom the class floors (`minimumWidthPoints`) hold the stroke
    /// readable where the world width thins.
    static func streetStrokeWidthPoints(cls: String?) -> Float {
        switch cls {
        case "motorway": return 14
        case "trunk": return 13
        case "primary": return 12
        case "secondary": return 10
        case "tertiary": return 9
        case "minor": return 7
        case "service": return 4
        case "path", "track": return 2
        default: return 6
        }
    }

    /// The casing of a street map's stroke, per side, in points.
    static let streetStrokeCasingPointsPerSide: Double = 1

    /// Tile units per layout point of a z16 tile at camera zoom 16, the
    /// nominal scale the stroke ladder is designed at (the same scale the
    /// marking ribbons are provisioned at). It is a design constant rather
    /// than a camera fact: the camera projects by field of view, so the
    /// exact on-screen size varies a little with the viewport, which is
    /// what a stroke width in points tolerates by nature.
    static let streetStrokeUnitsPerPointAtStreetZoom: Double = 8

    /// Tile units per nominal point in this tile: the z16 scale halved for
    /// every level coarser, so a width stated in points at z16 is the same
    /// ground width in every tile that serves it.
    static func streetStrokeUnitsPerPoint(tile: Tile) -> Double {
        streetStrokeUnitsPerPointAtStreetZoom * pow(2.0, Double(tile.z - 16))
    }

    static func streetStrokeWidthUnits(cls: String?, tile: Tile) -> Double {
        Double(streetStrokeWidthPoints(cls: cls)) * streetStrokeUnitsPerPoint(tile: tile)
    }

    /// How much wider than the carriageway the casing draws, in metres per
    /// side: the kerb line, not a proportion of the road. A proportional
    /// casing was invisible on a symbolic width and metres wide on a true
    /// one.
    static let roadCasingMetresPerSide: Double = 0.7

    /// Multiplier applied to the (z14+) base road widths so roads are thin hairlines
    /// at country/regional zooms and reach full width at street level.
    func roadWidthScale(tileZoom: Int) -> Double {
        switch tileZoom {
        case ...7: return 0.15
        case 8: return 0.22
        case 9: return 0.30
        case 10: return 0.40
        case 11: return 0.52
        case 12: return 0.68
        case 13: return 0.84
        default: return 1.0
        }
    }

    func makeRoadGeometry(width: Double) -> LineGeometryStyle {
        LineGeometryStyle(lineWidth: width, lineCapRound: false, lineJoinRound: true)
    }

    func makeDashedRoadGeometry(width: Double,
                                dashLength: Double,
                                dashGap: Double) -> LineGeometryStyle {
        LineGeometryStyle(lineWidth: width,
                                             lineCapRound: true,
                                             lineJoinRound: false,
                                             dashLength: dashLength,
                                             dashGap: dashGap)
    }
}

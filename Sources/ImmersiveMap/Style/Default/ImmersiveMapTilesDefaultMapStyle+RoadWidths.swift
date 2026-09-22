// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// How wide a road is. A road is a symbol: the theme states its width on
/// screen in points per class (`RoadMetrics.symbolWidthPoints`), the
/// shader draws exactly that many points until the world lock zoom and the
/// ground width those points had there from then on. Nothing here reads a
/// lane count or a width off the tiles. What is measured on the ground
/// instead, the streetscape's surfaces and the paint on them, is stated in
/// metres and converted per tile.
extension ImmersiveMapTilesDefaultMapStyle {
    /// The equatorial circumference the Web Mercator tile grid is built on.
    static let equatorialCircumferenceMetres: Double = 40_075_016.686

    /// The canonical tile coordinate space every parsed geometry lives in
    /// (`TileCoordinateSpace.tileExtentDouble`).
    static let tileExtentUnits: Double = 4096

    /// Tile units per ground metre for one tile.
    ///
    /// A length on the ground (a crossing's band, the kerb of a measured
    /// surface, the period of a lane line's dashes) is stated in metres and
    /// converted here. Web Mercator's scale is a function of latitude, taken
    /// at the tile's own centre, and the tile's zoom sets how much ground its
    /// 4096 units span. Doing the conversion per tile is what makes a length
    /// the same on the ground whichever zoom's tile happens to serve it.
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

    /// The kerb of a measured surface (a junction area, a parking lot), in
    /// metres per side: a line on the ground, not a proportion of the
    /// surface.
    static let roadCasingMetresPerSide: Double = 0.7

    /// The casing of a road's symbol, per side, in points: the same margin
    /// the theme's casing switch (`RoadMetrics.drawsCasing`) adds around the
    /// overview stroke, so the tile level where the eras hand over changes
    /// nothing on screen.
    static let roadCasingPointsPerSide: Double = 1

    /// Tile units one layout point spans in a tile of the camera's own zoom,
    /// on the nominal viewport: 4096 units over the points the tile covers
    /// when the camera sits at the far point of its fractional-zoom dolly
    /// (distance one, the render camera's vertical field of view of pi/4)
    /// over a viewport 800 points tall, with the default globe radius scale
    /// (`ZoomAnchorMath`, `LineDashNominalScale`). A design constant rather
    /// than a camera fact: the camera projects by field of view, so the
    /// exact figure varies a little with the viewport, which is what a
    /// symbol stated in points tolerates by nature.
    static let nominalTileUnitsPerPointAtCameraZoom: Double = 4.8

    /// Tile units one layout point spans in this tile at a camera zoom, on
    /// the nominal viewport: the camera-zoom figure halved for every level
    /// the tile is coarser than the camera.
    static func nominalTileUnitsPerPoint(tile: Tile, cameraZoom: Float) -> Double {
        nominalTileUnitsPerPointAtCameraZoom * pow(2.0, Double(tile.z) - Double(cameraZoom))
    }

    /// The camera zoom a road's symbol is measured on the ground at: the
    /// theme's world lock, from which the symbol keeps its ground width, or
    /// where the theme keeps every road a symbol at every zoom, the zoom
    /// the paint on the roads comes in at.
    var symbolGroundZoom: Float {
        let lock = theme.roadMetrics.worldLockZoom
        return lock > 0 ? lock : Float(LowZoomOverviewFade.roadMarkingStartZoom)
    }

    /// The ground width of a class's symbol, in this tile's units: the
    /// width its points cover at the zoom the symbol is frozen on the
    /// ground, converted world-locked, so every tile level that serves the
    /// road bakes the same ground width. What is laid across the symbol
    /// (the lane lines, the inset of the paint at a junction) is measured
    /// against this, as the symbol is what the road is drawn as.
    func symbolGroundWidthUnits(cls: String?, tile: Tile) -> Double {
        Double(theme.roadMetrics.symbolWidthPoints.value(forClass: cls))
            * Self.nominalTileUnitsPerPoint(tile: tile, cameraZoom: symbolGroundZoom)
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
    /// the centreline, across a road `width` units wide. A road of
    /// `laneCount` lanes has `laneCount - 1` of them, evenly spaced; with an
    /// even count one of them is the centre.
    static func laneBoundaryOffsets(width: Double, laneCount: Int) -> [Double] {
        let lanes = max(laneCount, 1)
        guard lanes >= 2 else { return [] }
        let laneWidth = width / Double(lanes)
        return (1..<lanes).map { -width * 0.5 + laneWidth * Double($0) }
    }

    func makeRoadGeometry(width: Double) -> LineGeometryStyle {
        LineGeometryStyle(lineWidth: width, lineCapRound: false, lineJoinRound: true)
    }
}

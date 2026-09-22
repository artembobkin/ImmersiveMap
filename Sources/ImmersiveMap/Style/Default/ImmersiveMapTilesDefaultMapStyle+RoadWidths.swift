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
    /// surface, the period of a measured line's dashes) is stated in metres
    /// and converted here. Web Mercator's scale is a function of latitude,
    /// taken at the tile's own centre, and the tile's zoom sets how much
    /// ground its 4096 units span. Doing the conversion per tile is what
    /// makes a length the same on the ground whichever zoom's tile happens
    /// to serve it.
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

    func makeRoadGeometry(width: Double) -> LineGeometryStyle {
        LineGeometryStyle(lineWidth: width, lineCapRound: false, lineJoinRound: true)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// The buildings: extruded from the heights the schema reading states,
/// or, with the theme's extrusion off, the footprints as flat fills.
extension ProtomapsBasemapDefaultMapStyle {
    /// The height, in metres, of a building the tile states no height for.
    /// The basemap leaves `height` out when the source tags neither a height
    /// nor a storey count, which is common for low buildings, and without a
    /// fallback such a footprint stayed flat among its raised neighbours.
    /// Two storeys, the way the basemap itself converts a storey count
    /// (three metres a storey plus two).
    static let buildingFallbackHeightMetres: Float = 8

    func buildingStyle(facts: ImmersiveMapFeatureFacts, tileZoom: Int) -> FeatureStyle {
        // A feature of the layer the reading found to be no building (an
        // address point) draws nothing.
        guard tileZoom >= Self.buildingMinimumTileZoom, facts.building != nil else {
            return hiddenStyle
        }
        guard theme.features.buildingExtrusion else {
            // The same fill an extrusion draws under itself, and nothing
            // rises: how buildings draw on the globe, now on the plane too.
            return .fill(FillStyle(key: 30, color: theme.features.buildingFillColor))
        }
        return .extrusion(ExtrusionStyle(
            key: 30,
            color: theme.features.buildingFillColor,
            heightScale: 8.0,
            anchorZoom: 16,
            fallbackHeight: Self.buildingFallbackHeightMetres
        ))
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt

struct DetFeatureStyleData {
    let layerName: String
    let properties: [String: MvtValue]
    let tile: Tile
    /// Whether the map draws the streetscape (`TileSettings.StreetscapeSettings`).
    /// A road style reads it to decide between the measured carriageway and
    /// a street map's stroke: with the streetscape on, a road is drawn at
    /// its real width so the carriageway surfaces and paint of the second
    /// archive sit flush on it; with it off, a road is a stroke whose width
    /// is the class's alone, like every street map, and nothing about the
    /// ground's true dimensions is drawn.
    var streetscapeEnabled: Bool = true
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The tabs along the top of the debug panel: each shows the groups of one
/// category, and `all` shows every group at once, the way the panel was
/// before it had tabs, for the debugging that watches two groups together
/// (the stats while a control is toggled).
enum DebugOverlayPanelCategory: Int, CaseIterable {
    case all
    case stats
    case labels
    /// The sun and the hillshade of the slopes.
    case light
    /// The shadow map's settings.
    case shadows
    case sky
    /// The sun on the globe (`GlobeLightSettings`).
    case globe
    /// The air over the flat map: the ground fog's curves and its heights
    /// on the relief (`GroundFogSettings`).
    case air
    case map
    case tiles
    case relief
    case export

    var title: String {
        switch self {
        case .all: "All"
        case .stats: "Stats"
        case .labels: "Labels"
        case .light: "Light"
        case .shadows: "Shadows"
        case .sky: "Sky"
        case .globe: "Globe"
        case .air: "Air"
        case .map: "Map"
        case .tiles: "Tiles"
        case .relief: "Relief"
        case .export: "Export"
        }
    }

    /// Whether the panel, on this tab, shows the groups of a category.
    func shows(_ category: DebugOverlayPanelCategory) -> Bool {
        self == .all || self == category
    }
}

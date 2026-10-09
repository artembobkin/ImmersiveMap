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
    case shadows
    case sky
    case map
    case tiles
    case export

    var title: String {
        switch self {
        case .all: "All"
        case .stats: "Stats"
        case .labels: "Labels"
        case .shadows: "Shadows"
        case .sky: "Sky & fog"
        case .map: "Map"
        case .tiles: "Tiles"
        case .export: "Export"
        }
    }

    /// Whether the panel, on this tab, shows the groups of a category.
    func shows(_ category: DebugOverlayPanelCategory) -> Bool {
        self == .all || self == category
    }
}

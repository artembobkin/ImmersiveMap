// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// What the debug panel has been dragged to, kept apart from the settings the
/// app supplies.
///
/// SwiftUI calls `updateNSView` on every re-evaluation of the hierarchy and
/// hands the map the app's own settings value again. Without this, a slider in
/// the panel reverted the moment anything else on screen changed, so dragging
/// one felt like it did nothing at all. The panel's values ride on top of every
/// incoming settings value instead, and a drag holds until it is dragged
/// somewhere else.
///
/// The override is scoped to the debug panel being on: turning it off drops
/// the values, and the app's own settings come straight back.
struct DebugOverlaySettingsOverride: Equatable {
    var shadows: ImmersiveMapSettings.ShadowSettings?
    var sunDirection: SIMD3<Float>?

    var isEmpty: Bool {
        shadows == nil && sunDirection == nil
    }

    mutating func clear() {
        shadows = nil
        sunDirection = nil
    }

    func applied(to settings: ImmersiveMapSettings) -> ImmersiveMapSettings {
        guard settings.debug.enableDebugPanel, isEmpty == false else {
            return settings
        }

        var overridden = settings
        if let shadows {
            overridden.scene.shadows = shadows
        }
        if let sunDirection {
            overridden.scene.light.direction = sunDirection
        }
        return overridden
    }
}

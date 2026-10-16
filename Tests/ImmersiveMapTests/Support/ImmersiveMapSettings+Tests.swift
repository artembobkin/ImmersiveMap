// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap

extension ImmersiveMapSettings {
    /// The default map laid flat: the ground relief off, which the default
    /// turns on. What a test of the map on the plane starts from (the
    /// parse of a tile, its fills, roads and labels), so the flattening
    /// and the roads' rows at the grid that the relief brings stay out of
    /// what it checks.
    static var defaultWithoutRelief: ImmersiveMapSettings {
        ImmersiveMapSettings.default.groundRelief(isEnabled: false)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The colours of the trees that stand on the woods and the parks
/// (`TreeFillStyle`, `ImmersiveMapSettings.TreeSettings`). The tree model
/// carries no colour of its own, only which part a point belongs to and
/// how deep in the crown it lies, and the frame colours it from here: the
/// crown runs from `crownShadeColor` at its underside to `crownColor` at
/// its top, the trunk is `trunkColor`, each tree a shade lighter or darker
/// than the next. Drawn at frame time, never baked into the prepared
/// tiles, so a change needs no re-parse. RGB in 0...1.
public struct ImmersiveMapTreePalette: Equatable, Sendable {
    /// The crown's top, in the light.
    public var crownColor: SIMD3<Float>
    /// The crown's underside, in its own shade.
    public var crownShadeColor: SIMD3<Float>
    public var trunkColor: SIMD3<Float>

    public init(crownColor: SIMD3<Float> = SIMD3<Float>(0.64, 0.82, 0.46),
                crownShadeColor: SIMD3<Float> = SIMD3<Float>(0.40, 0.63, 0.36),
                trunkColor: SIMD3<Float> = SIMD3<Float>(0.48, 0.36, 0.25)) {
        self.crownColor = crownColor
        self.crownShadeColor = crownShadeColor
        self.trunkColor = trunkColor
    }

    /// The day's trees: a crown a touch deeper than the map's wood, so a
    /// tree reads on it, lightening to the wood's own tone at the top.
    public static let `default` = ImmersiveMapTreePalette()

    /// The night's trees, for the night palette
    /// (`ProtomapsBasemapTheme.night`): the crown a dim green over the
    /// night's wood, the trunk nearly lost in the dark.
    public static let night = ImmersiveMapTreePalette(crownColor: SIMD3<Float>(0.17, 0.30, 0.22),
                                                      crownShadeColor: SIMD3<Float>(0.08, 0.16, 0.13),
                                                      trunkColor: SIMD3<Float>(0.14, 0.12, 0.11))
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The colours of what no tile paints, stated by the style like every other
/// colour of the map: the map's ground where no tile has arrived yet (the
/// flat map's clear colour, and the tint of its horizon fog), and the two
/// polar caps past the last Mercator tile row, the north continuing the
/// open ocean and the south the ice sheet. The built-in style takes all
/// three from its theme, so a recolour of the land, the water and the ice
/// carries to them by itself.
public struct ImmersiveMapBaseColors: Equatable, Sendable {
    public var map: SIMD4<Float>
    public var northCap: SIMD4<Float>
    public var southCap: SIMD4<Float>

    public init(map: SIMD4<Float>, northCap: SIMD4<Float>, southCap: SIMD4<Float>) {
        self.map = map
        self.northCap = northCap
        self.southCap = southCap
    }
}

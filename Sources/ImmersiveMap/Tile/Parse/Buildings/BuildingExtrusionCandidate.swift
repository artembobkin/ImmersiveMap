// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A building footprint that will be extruded once the whole tile has been
/// read: the resolver needs every candidate of a building (and of the
/// buildings around it) before it can tell an outline from a part.
struct BuildingExtrusionCandidate {
    let styleKey: UInt8
    let buildingId: UInt64
    let footprintSignature: BuildingFootprintSignature
    // All rings are RENDER space (y up): the extrusion path works in
    // the same space as the roof tessellation it merges with, and enters
    // it exactly once, at candidate construction in the building reader.
    let clippedExterior: [SIMD2<Float>]
    let clippedInteriors: [[SIMD2<Float>]]
    /// The exterior ring as the tile carries it, before the clip to the
    /// tile square, in the same converted coordinates as `clippedExterior`.
    /// The roof frame must come from this whole footprint, never from the
    /// clipped one, or ridges break at tile edges.
    let unclippedExterior: [SIMD2<Float>]
    let hasUnclippedInteriorRings: Bool
    let roof: ParsedPolygon
    let roofInfo: RoofInfo?
    let baseHeight: Float
    let topHeight: Float
}

/// A building's vertical extent in tile units at the tile's zoom, and the
/// roof it carries when shaped roofs are on.
struct BuildingExtrusionHeights {
    let base: Float
    let top: Float
    let roof: RoofInfo?
}

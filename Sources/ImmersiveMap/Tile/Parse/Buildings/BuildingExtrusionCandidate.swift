// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A building footprint that will be extruded once the whole tile has been
/// read: the resolver needs every candidate of a building (and of the
/// buildings around it) before it can tell an outline from a part.
struct BuildingExtrusionCandidate {
    let styleKey: UInt8
    let buildingId: UInt64
    /// A `building:part` rather than a building outline. The resolver
    /// drops an outline that ground-standing parts already cover.
    let isPart: Bool
    let footprintSignature: BuildingFootprintSignature
    // All rings are RENDER space (y up): the extrusion path works in
    // the same space as the lid tessellation it merges with, and enters
    // it exactly once, at candidate construction in the building reader.
    let clippedExterior: [SIMD2<Float>]
    let clippedInteriors: [[SIMD2<Float>]]
    /// The flat lid's triangulation of the clipped footprint.
    let roof: ParsedPolygon
    let baseHeight: Float
    let topHeight: Float
}

/// A building's vertical extent in tile units at the tile's zoom.
struct BuildingExtrusionHeights {
    let base: Float
    let top: Float
}

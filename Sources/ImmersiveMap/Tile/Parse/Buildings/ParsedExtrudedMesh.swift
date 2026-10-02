// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// One building's extruded geometry before unification: walls and roof in
/// render space with a per-surface id.
struct ParsedExtrudedVertex {
    let position: SIMD3<Float>
    let normal: SIMD3<Float>
    let surfaceID: UInt32
}

struct ParsedExtrudedMesh {
    var vertices: [ParsedExtrudedVertex]
    var indices: [UInt32]
    /// The tile feature id of the building the volume is, zero for a
    /// feature without one.
    var buildingID: UInt64 = 0
}

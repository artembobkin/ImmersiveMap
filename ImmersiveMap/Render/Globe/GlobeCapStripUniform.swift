// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Per-cap fragment uniform of the cap shader; mirrors `GlobeCapStrip` in
/// Globe.metal (layout pinned by `GlobeCapStripSamplerTests`).
struct GlobeCapStripUniform {
    /// Nonzero once the strip has been baked at least once; before that the
    /// cap paints the palette colours.
    var hasStrip: UInt32
    /// See `GlobeCapStripSampler.poleMeanLod`.
    var poleMeanLod: Float
    var padding: SIMD2<Float> = .zero

    init(hasStrip: Bool, poleMeanLod: Float) {
        self.hasStrip = hasStrip ? 1 : 0
        self.poleMeanLod = poleMeanLod
    }
}

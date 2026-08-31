// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Whether this frame's globe surface vertices take the pure-sphere path.
///
/// At transition 0 the surface IS the sphere: the flat morph target, the
/// unfurl phase (an `acos` per vertex) and the mix between them contribute
/// nothing, so the vertex stages carry a function-constant specialization
/// that folds them away. The moment the sphere starts unfurling, the full
/// morph path returns. One rule, consulted by the placeholder fill and the
/// tile geometry alike, so the two can never disagree within a frame; the
/// deferred-lighting gate (`GlobeSurfaceLightingPath.isDeferred`) is a
/// strict subset of this one, so every unlit frame is also a pure-sphere
/// frame.
enum GlobeSphereVertexPath {
    static func isPureSphere(renderSurfaceMode: ViewMode, transition: Float) -> Bool {
        renderSurfaceMode == .spherical && transition == 0
    }
}

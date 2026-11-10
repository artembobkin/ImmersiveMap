// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Whether a chunk of a layer can reach the view on the flat map, where a
/// chunk lies on the plane under one matrix. The four corners of its box go
/// to clip space, and the chunk is left out when all four are beyond one
/// edge of the view, or behind the camera. Never leaves out a chunk that
/// shows: the test is the box's, not the shapes', and the edges are moved
/// out by what a line or a point adds round its position on screen. Pure,
/// testable alone.
enum LayerChunkCulling {
    /// The pixels the shaders add round a line's and a disc's extent for
    /// their smooth edge, and one more for the rounding of the matrices.
    static let edgeSlackPx: Float = 2

    /// - Parameters:
    ///   - clipFromLocal: the matrix a vertex of the chunk is drawn under,
    ///     the camera's by the chunk's own.
    ///   - reachPx: how far past its position a shape of the chunk reaches
    ///     on screen, in pixels.
    static func isVisible(boundsMinimum: SIMD2<Float>,
                          boundsMaximum: SIMD2<Float>,
                          clipFromLocal: matrix_float4x4,
                          reachPx: Float,
                          viewportSizePx: SIMD2<Float>) -> Bool {
        // A chunk no position was added to: nothing to leave out.
        guard boundsMinimum.x <= boundsMaximum.x, boundsMinimum.y <= boundsMaximum.y else { return true }
        guard viewportSizePx.x > 0, viewportSizePx.y > 0 else { return true }
        let margin = SIMD2<Float>(repeating: 1) + (reachPx + edgeSlackPx) * 2 / viewportSizePx
        let corners = [SIMD2<Float>(boundsMinimum.x, boundsMinimum.y), SIMD2<Float>(boundsMaximum.x, boundsMinimum.y),
                       SIMD2<Float>(boundsMinimum.x, boundsMaximum.y), SIMD2<Float>(boundsMaximum.x, boundsMaximum.y)]
            .map { clipFromLocal * SIMD4<Float>($0.x, $0.y, 0, 1) }
        // Each test is linear in clip space, so four corners on its far
        // side put the whole box there. The depth is not tested: a layer
        // draws at one depth of its own, whatever the camera's far plane.
        let outsideTests: [(SIMD4<Float>) -> Bool] = [
            { $0.x + margin.x * $0.w < 0 },
            { -$0.x + margin.x * $0.w < 0 },
            { $0.y + margin.y * $0.w < 0 },
            { -$0.y + margin.y * $0.w < 0 },
            { $0.w <= 0 }
        ]
        return outsideTests.contains { isOutside in corners.allSatisfy(isOutside) } == false
    }
}

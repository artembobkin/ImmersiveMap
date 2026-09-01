// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// One contiguous run of ground indices belonging to one style, in paint
/// order (the parser emits the ground bucket grouped by ascending style, so
/// run order is bottom-to-top layer order). POD with an explicit layout: the
/// disk codec stores the array byte-wise.
///
/// The runs are what lets the sphere drawer draw the ground as layers
/// instead of one call: the opaque layers front-to-back under a depth test,
/// so a pixel is shaded once by its topmost opaque layer, and the
/// translucent ones back-to-front blending over the result.
struct GroundStyleRun: Equatable, Sendable {
    /// First index element of the run and its length, in index elements.
    var indexStart: UInt32
    var indexCount: UInt32
    /// The style's zoom-fade mask (see `tileStyleFade`); the drawer combines
    /// it with the frame's fade alphas to decide whether the style is opaque
    /// this frame.
    var fadeMask: Float
    /// Bit 0: both palette colours of the style carry alpha 1, so the run is
    /// opaque whenever its fade is 1.
    var flags: UInt32

    static let alphaOpaqueFlag: UInt32 = 1

    var isAlphaOpaque: Bool {
        flags & Self.alphaOpaqueFlag != 0
    }
}

enum GroundStyleRunScanner {
    /// Splits the ground index buffer into per-style runs. The parser's
    /// contract is one contiguous run per style in ascending style order
    /// (`unifyPolygonLayer` appends per sorted style key); a violation falls
    /// back to a single translucent run covering everything, which draws
    /// exactly like the unsplit path.
    static func scan(ground: PreparedTileCPU.GeometryLayer) -> [GroundStyleRun] {
        let indices = ground.indices
        let vertices = ground.vertices
        guard indices.isEmpty == false else { return [] }

        var runs: [GroundStyleRun] = []
        var runStart = 0
        var runStyle = -1
        var triangleStart = 0
        while triangleStart + 2 < indices.count {
            let vertexIndex = Int(indices[triangleStart])
            guard vertexIndex < vertices.count else { return fallback(ground: ground) }
            let style = Int(vertices[vertexIndex].styleIndex)
            if style != runStyle {
                guard style > runStyle else { return fallback(ground: ground) }
                if runStyle >= 0 {
                    runs.append(makeRun(styleIndex: runStyle,
                                        start: runStart,
                                        count: triangleStart - runStart,
                                        ground: ground))
                }
                runStyle = style
                runStart = triangleStart
            }
            triangleStart += 3
        }
        if runStyle >= 0 {
            runs.append(makeRun(styleIndex: runStyle,
                                start: runStart,
                                count: indices.count - runStart,
                                ground: ground))
        }
        return runs
    }

    private static func makeRun(styleIndex: Int, start: Int, count: Int,
                                ground: PreparedTileCPU.GeometryLayer) -> GroundStyleRun {
        var flags: UInt32 = 0
        if styleIndex < ground.styles.count {
            let style = ground.styles[styleIndex]
            if style.color.w >= 1.0, style.streetColor.w >= 1.0 {
                flags |= GroundStyleRun.alphaOpaqueFlag
            }
        }
        let fadeMask = styleIndex < ground.overviewStyleMasks.count
            ? ground.overviewStyleMasks[styleIndex] : 0
        return GroundStyleRun(indexStart: UInt32(start),
                              indexCount: UInt32(count),
                              fadeMask: fadeMask,
                              flags: flags)
    }

    private static func fallback(ground: PreparedTileCPU.GeometryLayer) -> [GroundStyleRun] {
        assertionFailure("Ground indices are not grouped by ascending style")
        return [GroundStyleRun(indexStart: 0,
                               indexCount: UInt32(ground.indices.count),
                               fadeMask: 0,
                               flags: 0)]
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// One contiguous run of ground indices belonging to one style and one
/// geometry class, in paint order. The parser emits the ground bucket as two
/// class segments, polygon fills first and line ribbons second, each grouped
/// by ascending style, so run order is bottom-to-top layer order. POD with an
/// explicit layout: the disk codec stores the array byte-wise.
///
/// The runs are what lets the sphere drawer draw the ground as class passes:
/// the opaque fill layers front-to-back under a depth test, so a pixel is
/// shaded once by its topmost opaque layer, the translucent fills
/// back-to-front blending over the result, and the ribbons last through the
/// line-field pipeline, without either class pass reading the other's
/// vertices.
struct GroundStyleRun: Equatable, Sendable {
    /// First index element of the run and its length, in index elements.
    var indexStart: UInt32
    var indexCount: UInt32
    /// The style's zoom-fade mask (see `tileStyleFade`); the drawer combines
    /// it with the frame's fade alphas to decide whether the style is opaque
    /// this frame.
    var fadeMask: Float
    /// Bit 0: both palette colours of the style carry alpha 1, so the run is
    /// opaque whenever its fade is 1. Bit 1: the run is line ribbons and
    /// draws through the line-field pipeline.
    var flags: UInt32

    static let alphaOpaqueFlag: UInt32 = 1
    static let linesClassFlag: UInt32 = 2

    var isAlphaOpaque: Bool {
        flags & Self.alphaOpaqueFlag != 0
    }

    var isLinesClass: Bool {
        flags & Self.linesClassFlag != 0
    }
}

enum GroundStyleRunScanner {
    /// Splits the ground index buffer into per-style, per-class runs. The
    /// parser's contract is two class segments meeting at
    /// `ground.fillsIndexCount`, each one contiguous run per style in
    /// ascending style order (`unifyPolygonLayer(splitLinesClass:)`); a
    /// violation falls back to a single ribbons-class run covering
    /// everything, which draws exactly like the unsplit combined path.
    static func scan(ground: PreparedTileCPU.GeometryLayer) -> [GroundStyleRun] {
        guard ground.indices.isEmpty == false else { return [] }
        let boundary = min(max(ground.fillsIndexCount, 0), ground.indices.count)
        guard boundary % 3 == 0 else { return fallback(ground: ground) }

        guard let fills = scanSegment(ground: ground,
                                      start: 0,
                                      end: boundary,
                                      classFlags: 0),
              let ribbons = scanSegment(ground: ground,
                                        start: boundary,
                                        end: ground.indices.count,
                                        classFlags: GroundStyleRun.linesClassFlag) else {
            return fallback(ground: ground)
        }
        return fills + ribbons
    }

    private static func scanSegment(ground: PreparedTileCPU.GeometryLayer,
                                    start: Int,
                                    end: Int,
                                    classFlags: UInt32) -> [GroundStyleRun]? {
        let indices = ground.indices
        let vertices = ground.vertices
        var runs: [GroundStyleRun] = []
        var runStart = start
        var runStyle = -1
        var triangleStart = start
        while triangleStart + 2 < end {
            let vertexIndex = Int(indices[triangleStart])
            guard vertexIndex < vertices.count else { return nil }
            let style = Int(vertices[vertexIndex].styleIndex)
            if style != runStyle {
                guard style > runStyle else { return nil }
                if runStyle >= 0 {
                    runs.append(makeRun(styleIndex: runStyle,
                                        start: runStart,
                                        count: triangleStart - runStart,
                                        classFlags: classFlags,
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
                                count: end - runStart,
                                classFlags: classFlags,
                                ground: ground))
        }
        return runs
    }

    private static func makeRun(styleIndex: Int, start: Int, count: Int,
                                classFlags: UInt32,
                                ground: PreparedTileCPU.GeometryLayer) -> GroundStyleRun {
        var flags: UInt32 = classFlags
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
        assertionFailure("Ground indices are not two class segments grouped by ascending style")
        // The ribbons class draws through the line-field pipeline, under
        // which fills paint with coverage 1: one combined translucent run
        // paints exactly like the unsplit path.
        return [GroundStyleRun(indexStart: 0,
                               indexCount: UInt32(ground.indices.count),
                               fadeMask: 0,
                               flags: GroundStyleRun.linesClassFlag)]
    }
}

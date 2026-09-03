// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// One contiguous run of ground indices belonging to one style and one
/// geometry class, in paint order. The parser emits the ground bucket as
/// three class segments, polygon fills first, line ribbons second and the
/// fills' outlines third, each grouped by ascending style, so run order
/// within a class is bottom-to-top layer order. POD with an explicit layout:
/// the disk codec stores the array byte-wise.
///
/// The runs are what lets the ground drawers draw the ground as class
/// passes: the opaque fill layers under a depth write (their rank depth,
/// computed in the vertex stage from the style index, lets hidden surface
/// removal shade a pixel once by its topmost opaque layer), the translucent
/// fills blending bottom-to-top over the result, and the ribbons last
/// through the line-field pipeline, without either class pass reading the
/// other's vertices; adjacent runs headed for the same pass merge into one
/// draw. The outline runs are a LINE list (index pairs), which only the flat
/// drawer rasterizes, right after the opaque fills and only for the styles
/// opaque that frame; the sphere never draws them.
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
    /// draws through the line-field pipeline. Bit 2: the run is fill
    /// outlines, a line list over the fill vertices.
    var flags: UInt32

    static let alphaOpaqueFlag: UInt32 = 1
    static let linesClassFlag: UInt32 = 2
    static let fillOutlineClassFlag: UInt32 = 4

    var isAlphaOpaque: Bool {
        flags & Self.alphaOpaqueFlag != 0
    }

    var isLinesClass: Bool {
        flags & Self.linesClassFlag != 0
    }

    var isFillOutlineClass: Bool {
        flags & Self.fillOutlineClassFlag != 0
    }

    /// The polygon fills: neither ribbons nor outlines.
    var isFillsClass: Bool {
        flags & (Self.linesClassFlag | Self.fillOutlineClassFlag) == 0
    }
}

enum GroundStyleRunScanner {
    /// Splits the ground index buffer into per-style, per-class runs. The
    /// parser's contract is three class segments, fills up to
    /// `ground.fillsIndexCount`, ribbons up to `ground.fillOutlinesIndexStart`
    /// and the fill outlines (index pairs) to the end, each one contiguous
    /// run per style in ascending style order
    /// (`unifyPolygonLayer(splitLinesClass:)`); a violation falls back to a
    /// single ribbons-class run covering everything, which draws exactly
    /// like the unsplit combined path.
    static func scan(ground: PreparedTileCPU.GeometryLayer) -> [GroundStyleRun] {
        guard ground.indices.isEmpty == false else { return [] }
        let outlinesStart = min(max(ground.fillOutlinesIndexStart, 0), ground.indices.count)
        let boundary = min(max(ground.fillsIndexCount, 0), outlinesStart)
        guard boundary % 3 == 0,
              (outlinesStart - boundary) % 3 == 0,
              (ground.indices.count - outlinesStart) % 2 == 0 else {
            return fallback(ground: ground)
        }

        guard let fills = scanSegment(ground: ground,
                                      start: 0,
                                      end: boundary,
                                      primitiveIndexCount: 3,
                                      classFlags: 0),
              let ribbons = scanSegment(ground: ground,
                                        start: boundary,
                                        end: outlinesStart,
                                        primitiveIndexCount: 3,
                                        classFlags: GroundStyleRun.linesClassFlag),
              let outlines = scanSegment(ground: ground,
                                         start: outlinesStart,
                                         end: ground.indices.count,
                                         primitiveIndexCount: 2,
                                         classFlags: GroundStyleRun.fillOutlineClassFlag) else {
            return fallback(ground: ground)
        }
        return fills + ribbons + outlines
    }

    private static func scanSegment(ground: PreparedTileCPU.GeometryLayer,
                                    start: Int,
                                    end: Int,
                                    primitiveIndexCount: Int,
                                    classFlags: UInt32) -> [GroundStyleRun]? {
        let indices = ground.indices
        let vertices = ground.vertices
        var runs: [GroundStyleRun] = []
        var runStart = start
        var runStyle = -1
        var triangleStart = start
        while triangleStart + primitiveIndexCount - 1 < end {
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
            triangleStart += primitiveIndexCount
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
        assertionFailure("Ground indices are not three class segments grouped by ascending style")
        // The ribbons class draws through the line-field pipeline, under
        // which fills paint with coverage 1: one combined translucent run
        // paints exactly like the unsplit path.
        return [GroundStyleRun(indexStart: 0,
                               indexCount: UInt32(ground.indices.count),
                               fadeMask: 0,
                               flags: GroundStyleRun.linesClassFlag)]
    }
}

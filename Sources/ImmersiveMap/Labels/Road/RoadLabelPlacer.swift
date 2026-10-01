// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Lays a tile's road glyphs along their roads on screen, on the CPU, in
/// the frame that draws them: the same numbers go to the collision solve
/// and to the road text vertex shader, so the boxes tested are the glyphs
/// drawn.
///
/// A record's paths are projected once (one tile, one origin), then each
/// path's arc length is accumulated once and every label instance on it
/// is placed from that: the anchor's distance along the path from the
/// anchor's own projected point, the reading direction from the label's
/// own span of the path (a stitched road that hooks back has a chord
/// pointing the wrong way), then each glyph at its offset from the anchor,
/// extrapolated straight past a path end where the label overhangs it. A
/// glyph is drawn when placed and the path is long enough for the label; a
/// path with any point behind the camera draws nothing.
enum RoadLabelPlacer {
    /// An anchor as the placer reads it: its path, the segment it sits on,
    /// and the index of its own point in the record's path points.
    struct Anchor {
        let pathIndex: Int32
        let segmentIndex: Int32
        let pointIndex: Int32
    }

    /// One tile record's roads and labels, fixed when the record is made.
    struct Geometry {
        /// Every path's points, path after path, then each anchor's own
        /// point (`RoadLabelCache.makeAnchorPointInput`).
        let pathPoints: [TilePointInput]
        /// Each path's points in `pathPoints`.
        let pathRanges: [Range<Int>]
        /// Each path's label instances, contiguous, in `anchors`.
        let pathInstanceRanges: [Range<Int>]
        /// Per instance.
        let anchors: [Anchor]
        /// Each instance's glyphs, contiguous, in `glyphs`.
        let instanceGlyphRanges: [Range<Int>]
        /// Per glyph, the array the vertex shader reads too.
        let glyphs: [RoadGlyphInput]
        /// Per glyph, the collision box in layout points before rotation.
        let glyphHalfSizes: [SIMD2<Float>]

        var glyphCount: Int {
            glyphs.count
        }
    }

    /// The projected paths, reused between records and frames.
    struct Scratch {
        var screenPoints: [SIMD2<Float>] = []
        var visible: [Bool] = []
        var cumulative: [Float] = []
    }

    /// Where a record's glyphs go this frame, index-aligned with the
    /// record's glyphs. `placements` is what the shader reads and the
    /// boxes are the collision solve's; `extrapolated` marks glyphs placed
    /// past a path end, drawn but never offered to the solve.
    struct Output {
        var placements: [RoadGlyphPlacementOutput] = []
        var extrapolated: [Bool] = []
        var boxHalfSizes: [SIMD2<Float>] = []

        mutating func resize(glyphCount: Int) {
            if placements.count != glyphCount {
                placements = Array(repeating: .hidden, count: glyphCount)
                extrapolated = Array(repeating: false, count: glyphCount)
                boxHalfSizes = Array(repeating: .zero, count: glyphCount)
            }
        }

        mutating func hideAll() {
            placements.withUnsafeMutableBufferPointer { placements in
                placements.update(repeating: .hidden)
            }
            extrapolated.withUnsafeMutableBufferPointer { flags in
                flags.update(repeating: false)
            }
        }
    }

    /// Projects the record's path points onto the flat map and places its
    /// glyphs. The record is one tile, so `origin` places all its points.
    static func place(geometry: Geometry,
                      origin: FlatTileOriginData,
                      cameraMatrix: simd_float4x4,
                      viewportSize: SIMD2<Float>,
                      pixelsPerPoint: Float,
                      scratch: inout Scratch,
                      output: inout Output) {
        project(pathPoints: geometry.pathPoints,
                origin: origin,
                cameraMatrix: cameraMatrix,
                viewportSize: viewportSize,
                screenPoints: &scratch.screenPoints,
                visible: &scratch.visible)
        place(geometry: geometry,
              screenPoints: scratch.screenPoints,
              visible: scratch.visible,
              pixelsPerPoint: pixelsPerPoint,
              cumulative: &scratch.cumulative,
              output: &output)
    }

    /// The flat projection of a tile's points, device pixels with the
    /// origin at the bottom left like the base labels' screen points. A
    /// point behind the camera is not visible.
    static func project(pathPoints: [TilePointInput],
                        origin: FlatTileOriginData,
                        cameraMatrix: simd_float4x4,
                        viewportSize: SIMD2<Float>,
                        screenPoints: inout [SIMD2<Float>],
                        visible: inout [Bool]) {
        let count = pathPoints.count
        if screenPoints.count != count {
            screenPoints = Array(repeating: .zero, count: count)
            visible = Array(repeating: false, count: count)
        }
        guard count > 0 else {
            return
        }
        let size = origin.size
        let panRelativeOrigin = origin.panRelativeOrigin
        let halfViewport = viewportSize * 0.5
        pathPoints.withUnsafeBufferPointer { points in
        screenPoints.withUnsafeMutableBufferPointer { screen in
        visible.withUnsafeMutableBufferPointer { visible in
            var index = 0
            while index < count {
                let uv = points[index].uv
                // v grows from the north edge, the flat render world is y-up.
                let world = SIMD4<Float>(panRelativeOrigin.x + uv.x * size,
                                         panRelativeOrigin.y + (1.0 - uv.y) * size,
                                         0.0,
                                         1.0)
                let clip = cameraMatrix * world
                if clip.w > 0.0 {
                    let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
                    screen[index] = (ndc + 1.0) * halfViewport
                    visible[index] = true
                } else {
                    screen[index] = .zero
                    visible[index] = false
                }
                index += 1
            }
        }}}
    }

    /// Places the record's glyphs from its projected path points.
    static func place(geometry: Geometry,
                      screenPoints: [SIMD2<Float>],
                      visible: [Bool],
                      pixelsPerPoint: Float,
                      cumulative: inout [Float],
                      output: inout Output) {
        output.resize(glyphCount: geometry.glyphCount)
        let longestPath = geometry.pathRanges.reduce(0) { max($0, $1.count) }
        if cumulative.count < longestPath {
            cumulative = Array(repeating: 0, count: longestPath)
        }
        guard geometry.glyphCount > 0, screenPoints.count == geometry.pathPoints.count else {
            output.hideAll()
            return
        }

        screenPoints.withUnsafeBufferPointer { points in
        visible.withUnsafeBufferPointer { visible in
        cumulative.withUnsafeMutableBufferPointer { cumulative in
        geometry.anchors.withUnsafeBufferPointer { anchors in
        geometry.glyphs.withUnsafeBufferPointer { glyphs in
        geometry.glyphHalfSizes.withUnsafeBufferPointer { glyphHalfSizes in
        output.placements.withUnsafeMutableBufferPointer { placements in
        output.extrapolated.withUnsafeMutableBufferPointer { extrapolated in
        output.boxHalfSizes.withUnsafeMutableBufferPointer { boxHalfSizes in
            for pathIndex in geometry.pathRanges.indices {
                let range = geometry.pathRanges[pathIndex]
                let instances = geometry.pathInstanceRanges[pathIndex]
                let start = range.lowerBound
                let count = range.count

                // The path's arc length, and whether all of it is in front
                // of the camera.
                var pathVisible = count >= 2
                if pathVisible {
                    cumulative[0] = 0
                    var previous = points[start]
                    pathVisible = visible[start]
                    var offset = 1
                    while offset < count {
                        let point = points[start + offset]
                        if visible[start + offset] == false {
                            pathVisible = false
                        }
                        cumulative[offset] = cumulative[offset - 1] + simd_length(point - previous)
                        previous = point
                        offset += 1
                    }
                }
                let totalLength: Float = count >= 2 ? cumulative[count - 1] : 0

                for instance in instances {
                    let anchor = anchors[instance]
                    let glyphRange = geometry.instanceGlyphRanges[instance]
                    guard pathVisible,
                          anchor.pointIndex >= 0, Int(anchor.pointIndex) < points.count,
                          visible[Int(anchor.pointIndex)],
                          glyphRange.isEmpty == false else {
                        for glyph in glyphRange {
                            placements[glyph] = .hidden
                            extrapolated[glyph] = false
                        }
                        continue
                    }

                    // The anchor's distance along the path: its own projected
                    // point dropped onto its segment. Lerping the world-space t
                    // along the projected segment is not the projection of the
                    // anchor under a tilted camera, and labels on long straight
                    // roads slid while tilting.
                    let segment = min(max(Int(anchor.segmentIndex), 0), count - 2)
                    let segmentStart = points[start + segment]
                    let segmentVector = points[start + segment + 1] - segmentStart
                    let segmentLength = cumulative[segment + 1] - cumulative[segment]
                    var along: Float = 0
                    if segmentLength > 0 {
                        let anchorPoint = points[Int(anchor.pointIndex)]
                        along = min(max(simd_dot(anchorPoint - segmentStart, segmentVector) / segmentLength, 0), segmentLength)
                    }
                    let anchorDistance = cumulative[segment] + along

                    // Which way the text reads: the label's own span of the
                    // path, half a label either side of the anchor, runs left
                    // on screen or right. A span too short to have a direction
                    // falls back to the anchor's segment.
                    let firstGlyph = glyphs[glyphRange.lowerBound]
                    let labelWidth = firstGlyph.labelWidth
                    let halfSpan = labelWidth * 0.5 * pixelsPerPoint
                    var span = pointAlongPath(points: points, start: start, count: count, cumulative: cumulative,
                                              distance: min(max(anchorDistance + halfSpan, 0), totalLength))
                        - pointAlongPath(points: points, start: start, count: count, cumulative: cumulative,
                                         distance: min(max(anchorDistance - halfSpan, 0), totalLength))
                    if simd_dot(span, span) <= 0 {
                        span = segmentVector
                    }
                    let reverse = span.x < 0
                    let canDraw = totalLength >= firstGlyph.minLength * pixelsPerPoint

                    for glyph in glyphRange {
                        let input = glyphs[glyph]
                        // Glyph metrics are in layout points; the arc length they
                        // are placed along is in device pixels.
                        var glyphOffset = (input.glyphCenter - labelWidth * 0.5) * pixelsPerPoint
                        if reverse {
                            glyphOffset = -glyphOffset
                        }
                        let targetDistance = anchorDistance + glyphOffset

                        var placed = false
                        var overhangs = false
                        var position = SIMD2<Float>.zero
                        var angle: Float = 0
                        if targetDistance <= 0 {
                            let p0 = points[start]
                            let direction = points[start + 1] - p0
                            let length = simd_length(direction)
                            if length > 0 {
                                position = p0 + direction / length * targetDistance
                                angle = atan2(direction.y, direction.x)
                                placed = true
                                overhangs = true
                            }
                        } else if targetDistance >= totalLength {
                            let p1 = points[start + count - 1]
                            let direction = p1 - points[start + count - 2]
                            let length = simd_length(direction)
                            if length > 0 {
                                position = p1 + direction / length * (targetDistance - totalLength)
                                angle = atan2(direction.y, direction.x)
                                placed = true
                                overhangs = true
                            }
                        } else {
                            var segment = 0
                            while segment < count - 1 {
                                let segmentLength = cumulative[segment + 1] - cumulative[segment]
                                if segmentLength > 0, cumulative[segment + 1] >= targetDistance {
                                    let t = (targetDistance - cumulative[segment]) / segmentLength
                                    let p0 = points[start + segment]
                                    let p1 = points[start + segment + 1]
                                    position = p0 + (p1 - p0) * t
                                    let direction = simd_normalize(p1 - p0)
                                    angle = atan2(direction.y, direction.x)
                                    placed = true
                                    break
                                }
                                segment += 1
                            }
                        }

                        if placed, reverse {
                            angle += .pi
                        }
                        let isVisible = placed && canDraw
                        placements[glyph] = RoadGlyphPlacementOutput(position: position,
                                                                     angle: angle,
                                                                     visible: isVisible ? 1 : 0)
                        extrapolated[glyph] = overhangs
                        if isVisible {
                            let halfSize = glyphHalfSizes[glyph] * pixelsPerPoint
                            let s = abs(sin(angle))
                            let c = abs(cos(angle))
                            boxHalfSizes[glyph] = SIMD2<Float>(c * halfSize.x + s * halfSize.y,
                                                               s * halfSize.x + c * halfSize.y)
                        } else {
                            boxHalfSizes[glyph] = .zero
                        }
                    }
                }
            }
        }}}}}}}}}
    }

    /// The point `distance` along the path from its start; the path's last
    /// point past its end.
    @inline(__always)
    private static func pointAlongPath(points: UnsafeBufferPointer<SIMD2<Float>>,
                                       start: Int,
                                       count: Int,
                                       cumulative: UnsafeMutableBufferPointer<Float>,
                                       distance: Float) -> SIMD2<Float> {
        var segment = 0
        while segment < count - 1 {
            let segmentLength = cumulative[segment + 1] - cumulative[segment]
            if segmentLength > 0, cumulative[segment + 1] >= distance {
                let t = min(max((distance - cumulative[segment]) / segmentLength, 0), 1)
                let p0 = points[start + segment]
                return p0 + (points[start + segment + 1] - p0) * t
            }
            segment += 1
        }
        return points[start + count - 1]
    }

    /// Appends the glyph boxes of one instance from the record's placement,
    /// for the collision solve. Returns false when the instance gets no
    /// decision: a hidden glyph (path behind the camera or shorter than
    /// the label), a glyph placed past a path end, or a turn between
    /// adjacent glyphs beyond `maxGlyphTurnRadians`, and then appends
    /// nothing.
    static func appendInstanceBoxes(glyphRange: Range<Int>,
                                    output: Output,
                                    maxGlyphTurnRadians: Float,
                                    centers: inout [SIMD2<Float>],
                                    halfSizes: inout [SIMD2<Float>]) -> Bool {
        guard glyphRange.isEmpty == false,
              glyphRange.lowerBound >= 0,
              glyphRange.upperBound <= output.placements.count else {
            return false
        }
        let boxStart = centers.count
        var previousAngle: Float?
        for glyph in glyphRange {
            let placement = output.placements[glyph]
            guard placement.visible != 0, output.extrapolated[glyph] == false else {
                centers.removeSubrange(boxStart...)
                halfSizes.removeSubrange(boxStart...)
                return false
            }
            if let previousAngle,
               abs(normalizedAngleDelta(lhs: previousAngle, rhs: placement.angle)) > maxGlyphTurnRadians {
                centers.removeSubrange(boxStart...)
                halfSizes.removeSubrange(boxStart...)
                return false
            }
            previousAngle = placement.angle
            centers.append(placement.position)
            halfSizes.append(output.boxHalfSizes[glyph])
        }
        return true
    }

    static func normalizedAngleDelta(lhs: Float, rhs: Float) -> Float {
        var delta = rhs - lhs
        while delta > .pi {
            delta -= 2 * .pi
        }
        while delta < -.pi {
            delta += 2 * .pi
        }
        return delta
    }
}

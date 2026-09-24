// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Bakes the labels painted on the map (`LabelPlacement.surface`) into glyph
/// quads anchored in the tile. Each vertex carries the label's anchor in
/// the tile's render units and its own offset from it in layout points, the
/// text laid out at its style's point size and centred on the anchor. How
/// many tile units a point spans is the frame's to say, since the map's
/// scale on screen follows the viewport (`SurfaceLabelScale`): the stage
/// that draws the text scales the offsets so it spans its point size at the
/// placement's reference zoom, and grows with the zoom from there like the
/// geometry around it.
final class TileSurfaceLabelsBuilder {
    private let textRenderer: TextRenderer

    init(textRenderer: TextRenderer) {
        self.textRenderer = textRenderer
    }

    /// A name wraps at this many ems to at most `wrapLineCount` lines,
    /// centred on each other.
    private static let wrapWidthEms: Float = 10
    private static let wrapLineCount = 3
    /// About the advance of an average letter, in ems: the box widens by
    /// the letter spacing over it, so a spaced-out name breaks at the same
    /// letters as a plain one.
    private static let averageAdvanceEms: Float = 0.55

    /// The surface labels among `textLabels`, the screen labels skipped.
    /// A label no zoom of this tile shows is not baked, nor a second label
    /// of a key the tile already carries.
    func build(textLabels: [ParsedTextLabel], tile: Tile) -> PreparedTileCPU.SurfaceLabelSet {
        var records: [SurfaceLabelRecord] = []
        var vertices: [LabelVertex] = []
        var bakedKeys = Set<UInt64>()
        let extent = Float(TileCoordinateSpace.tileExtentDouble)

        for label in textLabels {
            guard case .surface(let placement) = label.placement,
                  placement.isVisible(onTileZoom: tile.z),
                  bakedKeys.contains(label.key) == false else {
                continue
            }
            let style = label.textStyle
            let spacingWidening = 1 + max(placement.letterSpacingEm, 0) / Self.averageAdvanceEms
            let wrap = LabelWrapOptions(maxWidth: style.sizePoints * Self.wrapWidthEms * spacingWidening,
                                        maxLines: Self.wrapLineCount,
                                        alignment: .center)
            let metrics = textRenderer.collectLabelVertices(for: label.text,
                                                            labelIndex: simd_int1(records.count),
                                                            scale: style.sizePoints,
                                                            wrap: wrap,
                                                            weight: style.weight,
                                                            letterSpacing: placement.letterSpacingEm)
            guard metrics.vertices.isEmpty == false else { continue }

            // The anchor in render space: the parser's anchor is the tile's
            // y-down position, the ground's vertices run y up. The layout
            // runs y up too, so a glyph keeps its counter-clockwise winding.
            let anchor = SIMD2<Float>(Float(label.position.x), extent - Float(label.position.y))
            let halfSize = SIMD2<Float>(metrics.size.width, metrics.size.height) * 0.5
            let vertexStart = vertices.count
            for var vertex in metrics.vertices {
                // The sprite slot is free on a text glyph: it carries the
                // offset in points.
                vertex.spriteUV = vertex.position - halfSize
                vertex.position = anchor
                vertices.append(vertex)
            }
            records.append(SurfaceLabelRecord(key: label.key,
                                              style: style,
                                              placement: placement,
                                              vertexStart: vertexStart,
                                              vertexCount: vertices.count - vertexStart))
            bakedKeys.insert(label.key)
        }
        return PreparedTileCPU.SurfaceLabelSet(labels: records, vertices: vertices)
    }
}

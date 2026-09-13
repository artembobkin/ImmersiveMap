// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// The ground of a tile: the polygon fills that are neither a carriageway
/// surface nor a building's walls (a building's footprint is a ground fill
/// too, whether or not it rises), the ocean split that keeps a polygon with
/// hundreds of holes tessellable, and what every tile gets under and around
/// its features: the background quad, the debug frame, and the subdivision
/// that lets a coarse tile's triangles follow the sphere.
///
/// Stateless across tiles: the per-tile tessellator comes in as an argument.
struct GroundFeatureReader {
    /// An ocean polygon with this many holes or more is not tessellated as
    /// one polygon: its exterior draws as ocean and each hole as land, so
    /// earcut never sees the hundreds of islands of a coastal tile at once.
    static let complexOceanHoleSplitThreshold = 64

    private let mapStyle: MapStyleRuntime
    private let tileExtent = TileCoordinateSpace.tileExtentDouble

    init(mapStyle: MapStyleRuntime) {
        self.mapStyle = mapStyle
    }

    /// Whether a feature's polygons take the ocean split, decided once per
    /// feature: only a fill whose style asks for it, and only when one of
    /// its polygons is complex enough.
    func splitsComplexOceanHoles(style: FeatureStyle, polygons: MultiPolygon) -> Bool {
        style.splitsComplexHoles
            && polygons.contains { $0.interiorRings.count >= Self.complexOceanHoleSplitThreshold }
    }

    /// The ocean split for one polygon: its exterior as the feature's style,
    /// its holes as the background (land) style. Returns false when the
    /// polygon is not complex or its exterior does not tessellate, and the
    /// caller draws it the ordinary way.
    func appendComplexOceanPolygon(_ polygon: Polygon,
                                   style: FeatureStyle,
                                   into result: inout ReadingStageResult,
                                   parsePolygon: ParsePolygon,
                                   tile: Tile) -> Bool {
        guard polygon.interiorRings.count >= Self.complexOceanHoleSplitThreshold else {
            return false
        }

        let oceanPolygon = Polygon(exteriorRing: polygon.exteriorRing,
                                   interiorRings: [])
        guard let parsedOcean = parsePolygon.parse(polygon: oceanPolygon,
                                                   tileExtent: Float(tileExtent)) else {
            return false
        }

        result.polygonByStyle[style.key, default: []].append(parsedOcean)
        result.styles[style.key] = style

        let landStyle = mapStyle.backgroundStyle(tile: tile)
        guard landStyle.key != 0 else {
            return true
        }

        result.styles[landStyle.key] = landStyle
        for interiorRing in polygon.interiorRings {
            let landPolygon = Polygon(exteriorRing: interiorRing,
                                      interiorRings: [])
            if let parsedLand = parsePolygon.parse(polygon: landPolygon,
                                                   tileExtent: Float(tileExtent)) {
                result.polygonByStyle[landStyle.key, default: []].append(parsedLand)
            }
        }
        return true
    }

    /// After every layer is read: the background under everything, the
    /// debug frame when asked for, and the sphere subdivision of the whole
    /// ground bucket.
    func finish(tile: Tile, addTestBorders: Bool, into result: inout ReadingStageResult) {
        appendBackground(tile: tile, into: &result)
        if addTestBorders {
            appendBorder(width: 1, into: &result)
        }
        // The ground of a coarse tile is drawn straight onto the sphere:
        // split its triangles so their chords stay under a pixel of the
        // true surface (see GroundGeometrySubdivider).
        GroundGeometrySubdivider.subdivideIfNeeded(&result.polygonByStyle, tileZoom: tile.z)
    }

    private func appendBackground(tile: Tile, into result: inout ReadingStageResult) {
        // The real tile, not a placeholder: the background color is
        // zoom-banded (overview grass, land base, street land), and a
        // hardcoded z0 froze every tile on the overview branch, painting the
        // vegetation tone under the whole map at every zoom.
        let style = mapStyle.backgroundStyle(tile: tile)

        // One quad in render space, wound counter-clockwise like every
        // other ground triangle. The density the sphere needs is not decided
        // here: GroundGeometrySubdivider cuts it on the per-zoom grid like
        // any other ground polygon (64x64 cells at z0 and z1, down to 4x4 at
        // z9, untouched from z10 where the surface is flat), so the
        // background is exactly as fine as the ground around it. A 64x64
        // mesh built here carried 8192 triangles into every tile of every
        // zoom, most of them under a flat plane.
        let extent = Int16(tileExtent)
        let parsedPolygon = ParsedPolygon(vertices: [SIMD2(0, 0), SIMD2(extent, 0), SIMD2(extent, extent), SIMD2(0, extent)],
                                          indices: [0, 1, 2, 0, 2, 3])

        result.polygonByStyle[style.key, default: []].insert(parsedPolygon, at: 0)
        result.styles[style.key] = style
    }

    private func appendBorder(width borderWidth: Int16, into result: inout ReadingStageResult) {
        let style = mapStyle.debugBorderStyle()

        let tileSize: Int16 = 4096
        var polygons = [ParsedPolygon]()

        // Every rectangle lists bottom-left, bottom-right, top-left,
        // top-right; the two triangles are counter-clockwise in render space
        // like every other tile triangle.
        // Bottom border
        var vertices: [SIMD2<Int16>] = [
            SIMD2(0, 0),
            SIMD2(tileSize, 0),
            SIMD2(0, borderWidth),
            SIMD2(tileSize, borderWidth)
        ]
        var indices: [UInt32] = [0, 1, 2, 1, 3, 2]
        polygons.append(ParsedPolygon(vertices: vertices, indices: indices))

        // Top border
        vertices = [
            SIMD2(0, tileSize - borderWidth),
            SIMD2(tileSize, tileSize - borderWidth),
            SIMD2(0, tileSize),
            SIMD2(tileSize, tileSize)
        ]
        indices = [0, 1, 2, 1, 3, 2]
        polygons.append(ParsedPolygon(vertices: vertices, indices: indices))

        // Left border
        vertices = [
            SIMD2(0, 0),
            SIMD2(borderWidth, 0),
            SIMD2(0, tileSize),
            SIMD2(borderWidth, tileSize)
        ]
        indices = [0, 1, 2, 1, 3, 2]
        polygons.append(ParsedPolygon(vertices: vertices, indices: indices))

        // Right border
        vertices = [
            SIMD2(tileSize - borderWidth, 0),
            SIMD2(tileSize, 0),
            SIMD2(tileSize - borderWidth, tileSize),
            SIMD2(tileSize, tileSize)
        ]
        indices = [0, 1, 2, 1, 3, 2]
        polygons.append(ParsedPolygon(vertices: vertices, indices: indices))

        result.polygonByStyle[style.key] = polygons
        result.styles[style.key] = style
    }
}

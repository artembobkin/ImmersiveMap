// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// One rule of the flat map's coverage: the ground up to `distance` rings
/// of tiles from the look-at tile (and past the previous rule's rings) is
/// drawn `zoomDrop` levels below the target zoom. With `rasterized`, the
/// part of the band past the raster zone's start (`RasterZone`) draws as
/// each tile's picture, rendered once into a texture of `rasterResolution`
/// texels a side (`TileRasterizer`). Without it the band is geometry at
/// every distance.
struct FlatRingRule: Hashable {
    var zoomDrop: Int
    /// In tiles of the target zoom, counted on the grid from the look-at
    /// tile: 0 is that tile alone, 1 the three by three tiles around it,
    /// and so on. A ring number, not a radius, so a rule's edge runs along
    /// tile edges.
    var distance: Int
    /// The band's tiles may draw as pictures, where the raster zone says.
    var rasterized: Bool = false
    /// Texels a side of a rasterized tile, one of
    /// `FlatRingRules.rasterResolutions`.
    var rasterResolution: Int = FlatRingRules.defaultRasterResolution
    /// Whether the band's tiles draw their lines: the ground line ribbons
    /// (rivers, borders) and every road bucket. Off, the band is fills
    /// only, in a vector tile and in a rasterized tile's picture alike.
    var drawsLines: Bool = true

    init(zoomDrop: Int,
         distance: Int,
         rasterized: Bool = false,
         rasterResolution: Int = FlatRingRules.defaultRasterResolution,
         drawsLines: Bool = true) {
        self.zoomDrop = zoomDrop
        self.distance = distance
        self.rasterized = rasterized
        self.rasterResolution = rasterResolution
        self.drawsLines = drawsLines
    }
}

/// The rules, nearest first. Any number of them. The debug panel edits
/// the list, and both surfaces read it: the plane through
/// `FlatRingRuleCoverage`, the sphere through `GlobeTileCoverage`, which
/// reads every switch of a rule as the plane does.
struct FlatRingRules: Hashable {
    var rules: [FlatRingRule]

    static let zoomDropRange = 0 ... 8
    static let distanceRange = 0 ... 256
    /// The raster resolutions a rule can have, texels a side of one tile:
    /// the one size. A picture is kept per pictured tile with its mip
    /// chain, and a frame pictures dozens of tiles, so anything larger
    /// multiplies into memory the map cannot spend on its far ground. The
    /// far ground does not need more either: past the raster zone's start
    /// a tile is minified on screen.
    static let rasterResolutions = [256]
    static let defaultRasterResolution = 256

    /// The nearest of `rasterResolutions` to `resolution`.
    static func clampedRasterResolution(_ resolution: Int) -> Int {
        rasterResolutions.min { abs($0 - resolution) < abs($1 - resolution) } ?? defaultRasterResolution
    }

    /// The exact tiles to one ring around the look-at tile and one level
    /// coarser to ring 2, both with their lines, then two levels coarser
    /// to ring 3 and four levels coarser to ring 20, both without lines,
    /// nothing beyond.
    /// Every rule is rasterizable, so where the ground turns into pictures
    /// is the raster zone's distance alone and no rule's edge. The roads
    /// fade out by their width on screen inside the lined rings
    /// (`RoadThinnessFade`).
    static let `default` = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 1, rasterized: true),
                                                 FlatRingRule(zoomDrop: 1, distance: 2, rasterized: true),
                                                 FlatRingRule(zoomDrop: 2, distance: 3, rasterized: true,
                                                              drawsLines: false),
                                                 FlatRingRule(zoomDrop: 4, distance: 20, rasterized: true,
                                                              drawsLines: false)])

    /// The rules as the coverage reads them: every value inside its range,
    /// sorted by distance, one rule per distance, at least one rule.
    func normalized() -> FlatRingRules {
        var cleaned: [FlatRingRule] = []
        for rule in rules {
            let distance = min(max(rule.distance, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
            let drop = min(max(rule.zoomDrop, Self.zoomDropRange.lowerBound), Self.zoomDropRange.upperBound)
            cleaned.append(FlatRingRule(zoomDrop: drop,
                                        distance: distance,
                                        rasterized: rule.rasterized,
                                        rasterResolution: Self.clampedRasterResolution(rule.rasterResolution),
                                        drawsLines: rule.drawsLines))
        }
        cleaned.sort { $0.distance < $1.distance }
        var unique: [FlatRingRule] = []
        for rule in cleaned where unique.last.map({ $0.distance < rule.distance }) ?? true {
            unique.append(rule)
        }
        if unique.isEmpty {
            unique = Self.default.rules
        }
        return FlatRingRules(rules: unique)
    }
}

/// One rule's band as the frame resolved it: its zoom, its last ring,
/// how many tiles it placed and, for a rasterized rule, the resolution.
struct FlatRingBand: Hashable {
    let zoom: Int
    let distance: Int
    let tileCount: Int
    var rasterResolution: Int? = nil
}

struct FlatRingRuleCoverageResolution {
    static let empty = FlatRingRuleCoverageResolution(targets: [], bands: [], rasterizedTargets: [:],
                                                      linelessTargets: [], visitedNodeCount: 0)

    let targets: [VisibleTile]
    let bands: [FlatRingBand]
    /// The targets a rasterized rule placed, with the rule's resolution. A
    /// tile two bands share takes the nearer band's answer, so a tile of a
    /// vector band that reaches under a rasterized one stays vector.
    let rasterizedTargets: [VisibleTile: Int]
    /// The targets placed by a rule that draws no lines
    /// (`FlatRingRule.drawsLines`). A tile two bands share takes the nearer
    /// band's answer here too.
    let linelessTargets: Set<VisibleTile>
    /// How many tiles the enumeration looked at, for the diagnostics.
    let visitedNodeCount: Int
}

/// A rectangle of the flat render world along the tile grid's axes.
struct FlatRingSquare: Equatable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double
}

/// The flat map's coverage by ring rules (`FlatRingRules`): the ground in
/// view is cut into bands by the distance, in tiles, from the tile the
/// camera looks at, one band per rule, and each band is drawn at the
/// rule's zoom.
///
/// The look-at tile is the target zoom's tile under the point the camera
/// looks at (the render world's origin). A rule's square is that tile and
/// `distance` rings of target tiles around it, and a band's ground is the
/// frustum's footprint inside the rule's square and outside the previous
/// rule's. The look-at point stays where it is through a turn or a tilt
/// of the camera, and the squares run along the grid, so neither changes
/// a tile's rule: they change only what the footprint holds, as they
/// must. A pan moves the squares by whole tiles, when the look-at point
/// crosses a tile edge. A band's tiles are every tile of its zoom its
/// ground meets, so nothing outside the footprint is placed, and a coarse
/// tile is placed for the part of it that is in view. Where a coarse tile
/// of a farther band reaches under a nearer band, the nearer band's finer
/// tiles are drawn over it by the tile-priority stencil. Beyond the last
/// rule's square nothing is placed: the haze paints the horizon.
enum FlatRingRuleCoverage {
    /// How far a band's ground is drawn in from its squares' sides, in
    /// target tiles: well over the polygon test's tolerance, far under
    /// anything a tile could lie in.
    static let edgeInsetInTargetTiles = 1e-3

    static func resolve(flatRenderState: FlatRenderState,
                        targetZoom: Int,
                        backdropZoom: Int?,
                        rules: FlatRingRules,
                        polygon: CoveragePolygon) -> FlatRingRuleCoverageResolution {
        guard targetZoom >= 0 else { return .empty }
        let floorZoom = min(backdropZoom.map { $0 + 1 } ?? 0, targetZoom)

        var placed = Set<VisibleTile>()
        var rasterizedTargets: [VisibleTile: Int] = [:]
        var linelessTargets = Set<VisibleTile>()
        var bands: [FlatRingBand] = []
        var visited = 0
        var innerSquare: FlatRingSquare?
        let inset = flatRenderState.renderMapSize / Double(1 << targetZoom) * Self.edgeInsetInTargetTiles
        for rule in rules.normalized().rules {
            let zoom = max(floorZoom, targetZoom - rule.zoomDrop)
            let square = Self.square(rings: rule.distance, targetZoom: targetZoom, flatRenderState: flatRenderState)
            var tiles = Set<VisibleTile>()
            for ground in Self.bandPolygons(polygon, square: square, innerSquare: innerSquare, inset: inset) {
                tiles.formUnion(FlatTileCoverage.tiles(atZoom: zoom,
                                                       polygon: ground,
                                                       flatRenderState: flatRenderState,
                                                       visited: &visited))
            }
            if rule.rasterized {
                for tile in tiles where placed.contains(tile) == false {
                    rasterizedTargets[tile] = rule.rasterResolution
                }
            }
            if rule.drawsLines == false {
                linelessTargets.formUnion(tiles.subtracting(placed))
            }
            placed.formUnion(tiles)
            bands.append(FlatRingBand(zoom: zoom,
                                      distance: rule.distance,
                                      tileCount: tiles.count,
                                      rasterResolution: rule.rasterized ? rule.rasterResolution : nil))
            innerSquare = square
        }
        return FlatRingRuleCoverageResolution(targets: FlatTileCoverage.sorted(Array(placed)),
                                              bands: bands,
                                              rasterizedTargets: rasterizedTargets,
                                              linelessTargets: linelessTargets,
                                              visitedNodeCount: visited)
    }

    /// The target zoom's tile under the look-at point, which is the render
    /// world's origin: its column and row in the world copy the pan keeps
    /// under the camera.
    static func lookAtTile(targetZoom: Int, flatRenderState: FlatRenderState) -> (x: Int, y: Int) {
        let tilesCount = 1 << targetZoom
        let half = flatRenderState.renderMapSize * 0.5
        let tileSize = flatRenderState.renderMapSize / Double(tilesCount)
        // The inverse of `ImmersiveMapProjection.flatTileOriginAndSize` at
        // the origin. The row index grows south while the world is y-up.
        let column = Int(((half - flatRenderState.pan.x * half) / tileSize).rounded(.down))
        let rowFromSouth = Int(((half + flatRenderState.pan.y * half) / tileSize).rounded(.down))
        let clamp = { (value: Int) in min(max(value, 0), tilesCount - 1) }
        return (clamp(column), tilesCount - 1 - clamp(rowFromSouth))
    }

    /// The look-at tile and `rings` rings of target tiles around it, in
    /// world units.
    static func square(rings: Int, targetZoom: Int, flatRenderState: FlatRenderState) -> FlatRingSquare {
        let tile = lookAtTile(targetZoom: targetZoom, flatRenderState: flatRenderState)
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x, y: tile.y, z: targetZoom, worldWrap: 0,
                                                                  flatRenderPan: flatRenderState.pan,
                                                                  renderMapSize: flatRenderState.renderMapSize)
        let size = flatRenderState.renderMapSize / Double(1 << targetZoom)
        let reach = Double(rings) * size
        return FlatRingSquare(minX: Double(origin.x) - reach,
                              minY: Double(origin.y) - reach,
                              maxX: Double(origin.x) + size + reach,
                              maxY: Double(origin.y) + size + reach)
    }

    /// The footprint inside `square` and outside `innerSquare`: one convex
    /// piece with no inner square, otherwise the frame's four strips (the
    /// two full-height sides, then the top and the bottom between them),
    /// those of them the footprint reaches. Every piece is drawn in by
    /// `inset`, so a tile that only touches the band along an edge is not
    /// one of its tiles.
    static func bandPolygons(_ polygon: CoveragePolygon,
                             square: FlatRingSquare,
                             innerSquare: FlatRingSquare?,
                             inset: Double) -> [CoveragePolygon] {
        let outer = FlatRingSquare(minX: square.minX + inset, minY: square.minY + inset,
                                   maxX: square.maxX - inset, maxY: square.maxY - inset)
        guard let innerSquare else {
            return [clipped(polygon, to: outer)].compactMap { $0 }
        }
        let inner = FlatRingSquare(minX: innerSquare.minX - inset, minY: innerSquare.minY - inset,
                                   maxX: innerSquare.maxX + inset, maxY: innerSquare.maxY + inset)
        guard inner.minX > outer.minX || inner.maxX < outer.maxX || inner.minY > outer.minY || inner.maxY < outer.maxY else {
            return []
        }
        let strips = [FlatRingSquare(minX: outer.minX, minY: outer.minY, maxX: inner.minX, maxY: outer.maxY),
                      FlatRingSquare(minX: inner.maxX, minY: outer.minY, maxX: outer.maxX, maxY: outer.maxY),
                      FlatRingSquare(minX: inner.minX, minY: inner.maxY, maxX: inner.maxX, maxY: outer.maxY),
                      FlatRingSquare(minX: inner.minX, minY: outer.minY, maxX: inner.maxX, maxY: inner.minY)]
        return strips.compactMap { clipped(polygon, to: $0) }
    }

    /// The polygon's part inside the rectangle, nil when there is none.
    static func clipped(_ polygon: CoveragePolygon, to square: FlatRingSquare) -> CoveragePolygon? {
        guard square.maxX > square.minX, square.maxY > square.minY else { return nil }
        let centre = SIMD2<Double>((square.minX + square.maxX) / 2, (square.minY + square.maxY) / 2)
        let sides: [(SIMD2<Double>, SIMD2<Double>)] = [
            (SIMD2(square.minX, centre.y), SIMD2(square.minX, centre.y + 1)),
            (SIMD2(square.maxX, centre.y), SIMD2(square.maxX, centre.y + 1)),
            (SIMD2(centre.x, square.minY), SIMD2(centre.x + 1, square.minY)),
            (SIMD2(centre.x, square.maxY), SIMD2(centre.x + 1, square.maxY))
        ]
        var result: CoveragePolygon? = polygon
        for side in sides {
            result = result?.clipped(keepingSideOf: centre, ofLineFrom: side.0, to: side.1)
        }
        return result
    }
}

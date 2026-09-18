// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// One rule of the flat map's coverage: the ground up to `depth` camera
/// distances into the view (and past the previous rule's depth) is drawn
/// `zoomDrop` levels below the target zoom, as vector tiles or, with
/// `rasterized`, as each tile's picture rendered once into a texture of
/// `rasterResolution` texels a side (`TileRasterizer`).
struct FlatDepthRule: Hashable {
    var zoomDrop: Int
    /// In camera distances: 1 is the distance from the camera to the point
    /// it looks at, measured along the camera's view axis (the frustum's
    /// depth), so a rule's edge is one row of the screen.
    var depth: Double
    /// The band's tiles draw as textures instead of vector geometry.
    var rasterized: Bool = false
    /// Texels a side of a rasterized tile, one of
    /// `FlatDepthRules.rasterResolutions`.
    var rasterResolution: Int = FlatDepthRules.defaultRasterResolution

    init(zoomDrop: Int, depth: Double, rasterized: Bool = false, rasterResolution: Int = FlatDepthRules.defaultRasterResolution) {
        self.zoomDrop = zoomDrop
        self.depth = depth
        self.rasterized = rasterized
        self.rasterResolution = rasterResolution
    }
}

/// The rules, nearest first. Any number of them; the debug panel edits
/// the list.
struct FlatDepthRules: Hashable {
    var rules: [FlatDepthRule]

    static let zoomDropRange = 0 ... 8
    static let depthRange: ClosedRange<Double> = 0.25 ... 60
    /// The raster resolutions a rule can pick, texels a side of one tile.
    static let rasterResolutions = [256, 512, 1024, 2048]
    static let defaultRasterResolution = 512

    /// The nearest of `rasterResolutions` to `resolution`.
    static func clampedRasterResolution(_ resolution: Int) -> Int {
        rasterResolutions.min { abs($0 - resolution) < abs($1 - resolution) } ?? defaultRasterResolution
    }

    /// The exact tiles as vector geometry to a little past the look-at
    /// point, then rasterized bands: one level coarser at 512 texels to
    /// twice that depth, two levels coarser at 256 texels to about six
    /// camera distances, five levels coarser at 256 texels to about eight,
    /// the backdrop beyond.
    static let `default` = FlatDepthRules(rules: [FlatDepthRule(zoomDrop: 0, depth: 1.3, rasterized: false, rasterResolution: 1024),
                                                  FlatDepthRule(zoomDrop: 1, depth: 2.6, rasterized: true, rasterResolution: 512),
                                                  FlatDepthRule(zoomDrop: 2, depth: 5.86, rasterized: true, rasterResolution: 256),
                                                  FlatDepthRule(zoomDrop: 5, depth: 8.07, rasterized: true, rasterResolution: 256)])

    /// The rules as the coverage reads them: every value inside its range
    /// (a depth that is not a number falls to the range's start), sorted
    /// by depth, one rule per depth, at least one rule.
    func normalized() -> FlatDepthRules {
        var cleaned: [FlatDepthRule] = []
        for rule in rules {
            let depth = rule.depth.isFinite
                ? min(max(rule.depth, Self.depthRange.lowerBound), Self.depthRange.upperBound)
                : Self.depthRange.lowerBound
            let drop = min(max(rule.zoomDrop, Self.zoomDropRange.lowerBound), Self.zoomDropRange.upperBound)
            cleaned.append(FlatDepthRule(zoomDrop: drop,
                                         depth: depth,
                                         rasterized: rule.rasterized,
                                         rasterResolution: Self.clampedRasterResolution(rule.rasterResolution)))
        }
        cleaned.sort { $0.depth < $1.depth }
        var unique: [FlatDepthRule] = []
        for rule in cleaned where unique.last.map({ $0.depth < rule.depth }) ?? true {
            unique.append(rule)
        }
        if unique.isEmpty {
            unique = Self.default.rules
        }
        return FlatDepthRules(rules: unique)
    }
}

/// One rule's band as the frame resolved it: its zoom, its far depth,
/// how many tiles it placed and, for a rasterized rule, the resolution.
struct FlatDepthBand: Hashable {
    let zoom: Int
    let depth: Double
    let tileCount: Int
    var rasterResolution: Int? = nil
}

struct FlatDepthRuleCoverageResolution {
    static let empty = FlatDepthRuleCoverageResolution(targets: [], bands: [], rasterizedTargets: [:], visitedNodeCount: 0)

    let targets: [VisibleTile]
    let bands: [FlatDepthBand]
    /// The targets a rasterized rule placed, with the rule's resolution. A
    /// tile two bands share takes the nearer band's answer, so a tile of a
    /// vector band that reaches under a rasterized one stays vector.
    let rasterizedTargets: [VisibleTile: Int]
    /// How many tiles the enumeration looked at, for the diagnostics.
    let visitedNodeCount: Int
}

/// The flat map's coverage by depth rules (`FlatDepthRules`): the ground
/// in view is cut into bands by depth along the camera's view axis, one
/// band per rule, and each band is drawn at the rule's zoom.
///
/// A band's ground is the frustum's footprint cut by the two ground lines
/// where the depth equals the previous rule's and this rule's distance;
/// its tiles are every tile of the band's zoom the band's ground meets,
/// so a tile takes the rule of its nearest visible point. Where a coarse
/// tile of a farther band reaches under a nearer band, the nearer band's
/// finer tiles are drawn over it by the tile-priority stencil. Beyond the
/// last rule's depth nothing is placed: the backdrop and the haze paint
/// the horizon. Straight down the whole ground lies at one depth, the
/// camera distance, and belongs to the rule that covers depth 1.
enum FlatDepthRuleCoverage {
    static func resolve(eye: SIMD3<Float>,
                        flatRenderState: FlatRenderState,
                        targetZoom: Int,
                        backdropZoom: Int?,
                        rules: FlatDepthRules,
                        polygon: CoveragePolygon) -> FlatDepthRuleCoverageResolution {
        guard targetZoom >= 0 else { return .empty }
        let eye = SIMD3<Double>(Double(eye.x), Double(eye.y), Double(eye.z))
        let cameraDistance = simd_length(eye)
        guard cameraDistance > 1e-9, cameraDistance.isFinite else { return .empty }
        // The camera looks at the world origin: the view axis runs from
        // the eye to it.
        let direction = -eye / cameraDistance
        let floorZoom = min(backdropZoom.map { $0 + 1 } ?? 0, targetZoom)

        var placed = Set<VisibleTile>()
        var rasterizedTargets: [VisibleTile: Int] = [:]
        var bands: [FlatDepthBand] = []
        var visited = 0
        var previousDepth = 0.0
        for rule in rules.normalized().rules {
            let zoom = max(floorZoom, targetZoom - rule.zoomDrop)
            var count = 0
            if let bandPolygon = Self.bandPolygon(polygon,
                                                  eye: eye,
                                                  direction: direction,
                                                  nearDepth: previousDepth * cameraDistance,
                                                  farDepth: rule.depth * cameraDistance) {
                let tiles = FlatTileCoverage.tiles(atZoom: zoom,
                                                   polygon: bandPolygon,
                                                   flatRenderState: flatRenderState,
                                                   visited: &visited)
                count = tiles.count
                if rule.rasterized {
                    for tile in tiles where placed.contains(tile) == false {
                        rasterizedTargets[tile] = rule.rasterResolution
                    }
                }
                placed.formUnion(tiles)
            }
            bands.append(FlatDepthBand(zoom: zoom,
                                       depth: rule.depth,
                                       tileCount: count,
                                       rasterResolution: rule.rasterized ? rule.rasterResolution : nil))
            previousDepth = rule.depth
        }
        return FlatDepthRuleCoverageResolution(targets: FlatTileCoverage.sorted(Array(placed)),
                                               bands: bands,
                                               rasterizedTargets: rasterizedTargets,
                                               visitedNodeCount: visited)
    }

    /// The ground line where the view depth equals `depth` (world units):
    /// two points on it, nil when the view runs straight down and the
    /// ground has one depth everywhere.
    static func depthLine(eye: SIMD3<Double>, direction: SIMD3<Double>, depth: Double) -> (SIMD2<Double>, SIMD2<Double>)? {
        let normal = SIMD2<Double>(direction.x, direction.y)
        let lengthSquared = simd_length_squared(normal)
        guard lengthSquared > 1e-18 else { return nil }
        // dot(p - eye, direction) == depth on the ground, p.z == 0.
        let offset = depth + simd_dot(eye, direction)
        let foot = normal * (offset / lengthSquared)
        let along = SIMD2<Double>(-normal.y, normal.x) / lengthSquared.squareRoot()
        return (foot - along, foot + along)
    }

    /// The footprint's part between the two depths, nil when there is
    /// none. Straight down the ground's one depth is the eye's height,
    /// and the whole footprint belongs to the band that spans it.
    static func bandPolygon(_ polygon: CoveragePolygon,
                            eye: SIMD3<Double>,
                            direction: SIMD3<Double>,
                            nearDepth: Double,
                            farDepth: Double) -> CoveragePolygon? {
        guard farDepth > nearDepth else { return nil }
        let midDepth = (nearDepth + farDepth) / 2
        guard let nearLine = depthLine(eye: eye, direction: direction, depth: nearDepth),
              let farLine = depthLine(eye: eye, direction: direction, depth: farDepth),
              let midLine = depthLine(eye: eye, direction: direction, depth: midDepth) else {
            let groundDepth = simd_dot(SIMD3<Double>(eye.x, eye.y, 0) - eye, direction)
            return groundDepth > nearDepth && groundDepth <= farDepth ? polygon : nil
        }
        let inside = midLine.0
        guard let nearer = polygon.clipped(keepingSideOf: inside, ofLineFrom: nearLine.0, to: nearLine.1) else {
            return nil
        }
        return nearer.clipped(keepingSideOf: inside, ofLineFrom: farLine.0, to: farLine.1)
    }
}

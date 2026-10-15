// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The flat map's building coverage: which tiles draw their buildings
/// this frame.
///
/// The buildings follow the ground. Every tile the ground shows this frame
/// (`TilePlacementPlanner`), in its own slot or standing in, whose zoom is
/// the buildings' zoom or finer (`minimumDrawZoom(settings:)`), draws its
/// buildings, whole, in its own square: a tile's buildings are cut at its
/// edges by the parser, so tiles of different zooms side by side draw
/// each building once. Where two of them overlap, a tile standing in for
/// its loading children over ground some of them already show, the
/// coarser one draws and the finer ones wait: the buildings switch to the
/// finer tiles together, when the coarser one leaves the ground. So the
/// buildings stand through a change of zoom, as the ground does, and
/// never draw twice. The planner never demands a tile. The tiles farther
/// than `fieldRadiusInCells` from the eye's ground point are skipped:
/// buildings are a near-field feature.
enum BuildingCoveragePlanner {
    /// The coarsest tile zoom whose buildings are drawn. A tile coarser
    /// than the tileset's deepest zoom ships them merged into groups of one
    /// height, each polygon standing at its group's height
    /// (`TileParseOptions.buildingDeepestSourceZoom`). Coarser than this,
    /// the groups are too rough to stand. Also the grid the near field is
    /// measured in.
    static let minimumSourceZoom = 14
    /// How far from the eye's ground point, in grid cells, buildings are
    /// drawn.
    static let fieldRadiusInCells: Double = 3

    /// The tile zoom the buildings draw from: the zoom of the tiles a
    /// camera at `ExtrusionSettings.buildingsMinimumZoom` targets, within
    /// the tileset's zooms and never coarser than `minimumSourceZoom`. The
    /// parser extrudes no coarser tile (`TileParseOptions`).
    static func minimumDrawZoom(settings: ImmersiveMapSettings) -> Int {
        let minimumZoom = settings.scene.extrusion.buildingsMinimumZoom
        let wanted = minimumZoom.isFinite ? Int(max(minimumZoom, 0).rounded(.down)) : Int.max
        return max(minimumSourceZoom, min(wanted, settings.tiles.coverage.maximumZoomLevel))
    }

    /// The eye's ground point in grid cell units. The engine's camera looks
    /// at the world origin (the pan moves the world under it), so the eye
    /// is taken as it is: its x and y over the target zoom's tile size,
    /// away from the look-at point in tile units, with world y growing
    /// north while tile y grows south, then scaled to the grid's zoom.
    static func eyeGroundCell(eye: SIMD3<Float>,
                              flatRenderState: FlatRenderState,
                              lookAt: SIMD2<Double>,
                              targetZoom: Int) -> SIMD2<Double> {
        let tileUnits = flatRenderState.renderMapSize / Double(1 << max(0, targetZoom))
        let eyeGround = lookAt + SIMD2<Double>(Double(eye.x), -Double(eye.y)) / tileUnits
        return eyeGround * pow(2.0, Double(minimumSourceZoom - targetZoom))
    }

    /// `groundPlacements` are the frame's ground placements
    /// (`TilePlacementPlanner`). `eyeGroundCell` is the eye's ground point
    /// in grid cell units (a z14 tile is one unit), nil for the globe,
    /// where nothing is extruded. `minimumZoom` is the tile zoom the
    /// buildings draw from (`minimumDrawZoom(settings:)`).
    static func plan(groundPlacements: [PlaceTile],
                     eyeGroundCell: SIMD2<Double>?,
                     minimumZoom: Int = minimumSourceZoom) -> PlaceTilesContext {
        guard let eyeGroundCell else { return .empty }
        let floorZoom = max(minimumZoom, minimumSourceZoom)
        // The tiles the ground shows, by the world copy they show in.
        var sources: [VisibleTile: MetalTile] = [:]
        for placement in groundPlacements where placement.metalTile.tile.z >= floorZoom {
            sources[VisibleTile(tile: placement.metalTile.tile, worldWrap: placement.placeIn.worldWrap)] = placement.metalTile
        }
        let cellsCount = Double(1 << minimumSourceZoom)
        var result: [PlaceTile] = []
        for (square, metalTile) in sources {
            // A coarser tile drawing over this one's square draws its
            // buildings there.
            var isCovered = false
            var zoom = square.z - 1
            while zoom >= floorZoom, isCovered == false {
                if let ancestor = square.tile.findParentTile(atZoom: zoom),
                   sources[VisibleTile(tile: ancestor, worldWrap: square.worldWrap)] != nil {
                    isCovered = true
                }
                zoom -= 1
            }
            guard isCovered == false else { continue }
            let cellsPerTile = pow(2.0, Double(minimumSourceZoom - square.z))
            let center = SIMD2<Double>((Double(square.x) + 0.5) * cellsPerTile + Double(square.worldWrap) * cellsCount,
                                       (Double(square.y) + 0.5) * cellsPerTile)
            guard simd_length(center - eyeGroundCell) <= fieldRadiusInCells else {
                continue
            }
            result.append(PlaceTile(metalTile: metalTile, placeIn: square))
        }
        result.sort { lhs, rhs in
            if lhs.placeIn.worldWrap != rhs.placeIn.worldWrap {
                return lhs.placeIn.worldWrap < rhs.placeIn.worldWrap
            }
            if lhs.placeIn.z != rhs.placeIn.z {
                return lhs.placeIn.z < rhs.placeIn.z
            }
            if lhs.placeIn.x != rhs.placeIn.x {
                return lhs.placeIn.x < rhs.placeIn.x
            }
            return lhs.placeIn.y < rhs.placeIn.y
        }
        return PlaceTilesContext(tilePlacements: result)
    }
}

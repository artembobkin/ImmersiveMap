// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The flat map's building coverage: which resident tiles draw their
/// buildings this frame.
///
/// Only the frame's targets of its target zoom draw buildings, each in its
/// own place, once it is resident: a coarser tile standing in where they
/// have not arrived draws none, so the buildings never overlap and a tile
/// keeps its own buildings from the frame it arrives in. The planner never
/// demands a tile. The targets farther than `fieldRadiusInCells` from the
/// eye's ground point are skipped: buildings are a near-field feature. A
/// frame whose target zoom is below the buildings' zoom
/// (`minimumDrawZoom(settings:)`) plans none.
enum BuildingCoveragePlanner {
    /// The coarsest tile zoom that carries real buildings: coarser tiles
    /// merge them into blocks of one height and never draw them. Also the
    /// grid the near field is measured in.
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

    /// `resident` is every tile in the working set, `visibleTiles` the
    /// frame's coverage targets. `eyeGroundCell` is the eye's ground point
    /// in grid cell units (a z14 tile is one unit), nil for the globe,
    /// where nothing is extruded. `targetZoom` is the frame's target zoom,
    /// the finest target's when not given, and `minimumZoom` the tile zoom
    /// the buildings draw from (`minimumDrawZoom(settings:)`).
    static func plan(resident: [Tile: MetalTile],
                     visibleTiles: [VisibleTile],
                     eyeGroundCell: SIMD2<Double>?,
                     targetZoom: Int? = nil,
                     minimumZoom: Int = minimumSourceZoom) -> PlaceTilesContext {
        guard let eyeGroundCell,
              let targetZoom = targetZoom ?? visibleTiles.map(\.z).max(),
              targetZoom >= max(minimumZoom, minimumSourceZoom) else {
            return .empty
        }
        let cellsCount = Double(1 << minimumSourceZoom)
        let cellsPerTile = pow(2.0, Double(minimumSourceZoom - targetZoom))
        var planned = Set<VisibleTile>()
        var result: [PlaceTile] = []
        for target in visibleTiles where target.z == targetZoom {
            guard let metalTile = resident[target.tile], planned.insert(target).inserted else {
                continue
            }
            let center = SIMD2<Double>((Double(target.x) + 0.5) * cellsPerTile + Double(target.worldWrap) * cellsCount,
                                       (Double(target.y) + 0.5) * cellsPerTile)
            guard simd_length(center - eyeGroundCell) <= fieldRadiusInCells else {
                continue
            }
            result.append(PlaceTile(metalTile: metalTile, placeIn: target))
        }
        result.sort { lhs, rhs in
            if lhs.placeIn.worldWrap != rhs.placeIn.worldWrap {
                return lhs.placeIn.worldWrap < rhs.placeIn.worldWrap
            }
            if lhs.placeIn.x != rhs.placeIn.x {
                return lhs.placeIn.x < rhs.placeIn.x
            }
            return lhs.placeIn.y < rhs.placeIn.y
        }
        return PlaceTilesContext(tilePlacements: result)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The flat map's building coverage: which tiles draw their buildings
/// this frame.
///
/// The buildings follow the ground. Every tile the ground shows this frame
/// (`TilePlacementPlanner`), in its own slot or standing in, whose zoom is
/// the buildings' zoom or finer (`minimumDrawZoom(settings:)`), draws its
/// buildings in its own square: a tile's buildings are cut at its edges by
/// the parser, so tiles of different zooms side by side draw each building
/// once. Where two of them overlap (a tile standing in for its loading
/// children over ground some of them already show, a far ring's coarse
/// tile reaching under a nearer ring's finer tiles) the finer one draws:
/// a tile coarser than the tileset's deepest zoom keeps its buildings and
/// its trees by quarters, each cut at the quarters' edges as its children
/// cut theirs (`TileQuarters`), and draws only the quarters whose child is
/// not there (`PlaceTile.quarters`). So the finest buildings the ground
/// has stand, a building never draws twice, and no ground the coarse tile
/// covers is left without them. A tile kept whole that a finer tile lies
/// under draws whole and the finer one waits, as does a tile under a
/// coarser one's drawn quarter, which happens only with a tileset two
/// zooms deeper than the buildings start. The planner never demands a
/// tile, and keeps no field
/// of its own: how far the buildings reach is how far the ground's rings
/// place tiles of the buildings' zoom, so the camera's tilt changes which
/// tiles are in view and never which tile a building is drawn from.
enum BuildingCoveragePlanner {
    /// The coarsest tile zoom whose buildings are drawn. A tile coarser
    /// than the tileset's deepest zoom ships them merged into groups of one
    /// height, each polygon standing at its group's height
    /// (`TileParseOptions.buildingDeepestSourceZoom`). Coarser than this,
    /// the groups are too rough to stand.
    static let minimumSourceZoom = 14

    /// The tile zoom the buildings draw from: the zoom of the tiles a
    /// camera at `ExtrusionSettings.buildingsMinimumZoom` targets, within
    /// the tileset's zooms and never coarser than `minimumSourceZoom`. The
    /// parser extrudes no coarser tile (`TileParseOptions`).
    static func minimumDrawZoom(settings: ImmersiveMapSettings) -> Int {
        let minimumZoom = settings.scene.extrusion.buildingsMinimumZoom
        let wanted = minimumZoom.isFinite ? Int(max(minimumZoom, 0).rounded(.down)) : Int.max
        return max(minimumSourceZoom, min(wanted, settings.tiles.coverage.maximumZoomLevel))
    }

    /// `groundPlacements` are the frame's ground placements
    /// (`TilePlacementPlanner`). `onFlatMap` is false on the globe, where
    /// nothing is extruded. `minimumZoom` is the tile zoom the buildings
    /// draw from (`minimumDrawZoom(settings:)`).
    static func plan(groundPlacements: [PlaceTile],
                     onFlatMap: Bool,
                     minimumZoom: Int = minimumSourceZoom) -> PlaceTilesContext {
        guard onFlatMap else { return .empty }
        let floorZoom = max(minimumZoom, minimumSourceZoom)
        // The buildings rise by the terrain their ground's grid does.
        let displacementBySource = PlaceTilesContext(tilePlacements: groundPlacements).displacementBySource()
        // The tiles the ground shows, by the world copy they show in.
        var sources: [VisibleTile: MetalTile] = [:]
        for placement in groundPlacements where placement.metalTile.tile.z >= floorZoom {
            sources[VisibleTile(tile: placement.metalTile.tile, worldWrap: placement.placeIn.worldWrap)] = placement.metalTile
        }
        // From the coarsest down, so a tile knows what its ancestors draw:
        // the ground a tile drawn whole takes, and the squares of the
        // quarters drawn.
        var takenWhole: Set<VisibleTile> = []
        var takenQuarters: Set<VisibleTile> = []
        var result: [PlaceTile] = []
        let ordered = sources.sorted { $0.key.z < $1.key.z }
        for (square, metalTile) in ordered {
            var isTaken = false
            var zoom = square.z - 1
            while zoom >= floorZoom, isTaken == false {
                if let ancestor = square.tile.findParentTile(atZoom: zoom) {
                    let ground = VisibleTile(tile: ancestor, worldWrap: square.worldWrap)
                    isTaken = takenWhole.contains(ground) || takenQuarters.contains(ground)
                }
                zoom -= 1
            }
            guard isTaken == false else { continue }
            var quarters = TileQuarters.all
            if metalTile.tileBuffers.extruded.quarterIndexStarts.isEmpty {
                takenWhole.insert(square)
            } else {
                // A quarter whose child the ground shows is the child's.
                for quarter in 0..<TileQuarters.count {
                    let child = VisibleTile(tile: TileQuarters.child(of: square.tile, quarter: quarter),
                                            worldWrap: square.worldWrap)
                    if sources[child] != nil {
                        quarters &= ~(1 << quarter)
                    } else {
                        takenQuarters.insert(child)
                    }
                }
                guard quarters != 0 else { continue }
            }
            result.append(PlaceTile(metalTile: metalTile,
                                    placeIn: square,
                                    displacement: displacementBySource[metalTile.tile],
                                    quarters: quarters))
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

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The frame's ground, each point once: every placement's square
/// (`PlaceTile.placeIn`) less the finer squares inside it, which the
/// planner gives to the finer placements, the rest split into the largest
/// descendants that hold none of them. Placements overlap on the ground (a
/// finer one inside a coarser one, a child target under its parent), and
/// whatever has to draw the ground once per point, with no two placements
/// claiming the same ground, draws these squares: the placement prepass's
/// depth on the relief (`PlacementStencilRenderSubsystem`) and the
/// mountains' shadow casters (`GroundReliefShadowCasterSubsystem`).
/// Placements sharing a square take it once, from the last one, as the
/// last mark of a square is the one the stencil keeps.
struct PlacementGroundSquare: Hashable {
    /// A ground source as the ground draws it: the tile, the world copy,
    /// and the terrain its grid rises by (`PlaceTile.displacement`), nil on
    /// the plane.
    struct Source: Hashable {
        let tile: Tile
        let worldWrap: Int8
        let displacement: Tile?
    }

    let source: Source
    /// The source's tile itself or a square inside it.
    let square: VisibleTile

    /// The terrain each source (by tile and world copy) rises by wherever
    /// it draws: the finest of its placements' (`PlaceTile.displacement`).
    static func displacements(of placements: [PlaceTile]) -> [VisibleTile: Tile] {
        var terrains: [VisibleTile: Tile] = [:]
        for placement in placements {
            guard let terrain = placement.displacement else { continue }
            let source = VisibleTile(tile: placement.metalTile.tile, worldWrap: placement.placeIn.worldWrap)
            if terrain.z > (terrains[source]?.z ?? -1) {
                terrains[source] = terrain
            }
        }
        return terrains
    }

    /// The squares of a frame's placements, each point of the ground in
    /// exactly one.
    static func squares(of placements: [PlaceTile]) -> [PlacementGroundSquare] {
        let displacements = displacements(of: placements)
        var owners: [VisibleTile: PlaceTile] = [:]
        for placement in placements {
            owners[placement.placeIn] = placement
        }
        guard let shallowest = owners.keys.map(\.tile.z).min() else { return [] }
        // Every square with a finer square inside it.
        var holdsFiner: Set<VisibleTile> = []
        for square in owners.keys {
            var zoom = square.tile.z - 1
            while zoom >= shallowest, let ancestor = square.tile.findParentTile(atZoom: zoom),
                  holdsFiner.insert(VisibleTile(tile: ancestor, worldWrap: square.worldWrap)).inserted {
                zoom -= 1
            }
        }
        var squares: [PlacementGroundSquare] = []
        squares.reserveCapacity(owners.count)
        for (square, placement) in owners {
            let tile = placement.metalTile.tile
            let wrap = square.worldWrap
            let source = Source(tile: tile,
                                worldWrap: wrap,
                                displacement: displacements[VisibleTile(tile: tile, worldWrap: wrap)] ?? placement.displacement)
            var pending = [square]
            while let next = pending.popLast() {
                guard holdsFiner.contains(next) else {
                    squares.append(PlacementGroundSquare(source: source, square: next))
                    continue
                }
                let child = next.tile.z + 1
                for dy in 0 ... 1 {
                    for dx in 0 ... 1 {
                        let part = VisibleTile(x: next.tile.x * 2 + dx, y: next.tile.y * 2 + dy, z: child, worldWrap: wrap)
                        // A finer placement's own square is its to take.
                        if owners[part] == nil {
                            pending.append(part)
                        }
                    }
                }
            }
        }
        return squares
    }

    /// The cells a side a square takes of its source's grid of
    /// `sourceCells`, on the same lines: the source's cells over the part
    /// of it the square is, one at the least.
    static func cells(ofSource sourceCells: Int, sourceZoom: Int, squareZoom: Int) -> Int {
        max(1, sourceCells >> max(0, squareZoom - sourceZoom))
    }
}

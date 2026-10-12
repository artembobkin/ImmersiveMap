// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// What draws in a raster target's place while its texture is on its way:
/// the raster tiles' stand-ins, as `TilePlacementPlanner` finds the vector
/// tiles' from what is resident. A zoom crossing moves every ring to
/// another zoom, and the new bands' textures take a few frames to load or
/// bake, while the textures the last zoom's bands drew are still on the
/// GPU: without them the band is a hole, and whatever coarse far tile lies
/// under it shows through, its few texels smeared over the ground.
///
/// For a target without its texture, the vector planner's rules: its
/// resident descendants at any depth, placed whole, and, where those leave
/// a hole, its finest resident ancestor above `floorZoom`, placed in the
/// target's slot. The ground is partitioned by slot (`GroundSlotClip`), an
/// ancestor drawing around the descendants. A stand-in found for two
/// targets is placed once. A target the stand-ins do not cover whole, or
/// at all, is `uncovered`: the vector placements draw its ground, as a
/// vector target's, so a raster band is never a hole where a vector band
/// would not be.
enum RasterStandInPlanner {
    /// A resident texture, by the tile it draws, whatever its size.
    typealias Resident = [Tile: (key: RasterTileKey, texture: MTLTexture)]

    struct Plan {
        var placements: [RasterTilePlacement] = []
        var uncovered: [VisibleTile] = []
    }

    static func plan(forMissing targets: [VisibleTile],
                     resident: Resident,
                     floorZoom: Int?,
                     isPlaceable: (Tile) -> Bool = { _ in true }) -> Plan {
        guard targets.isEmpty == false else { return Plan() }
        guard resident.isEmpty == false else { return Plan(uncovered: targets) }
        var plan = Plan()
        var seen = Set<VisibleTile>()
        // The ancestors of every resident texture, so the descendant search
        // only descends into branches that hold one.
        var branches = Set<Tile>()
        for tile in resident.keys {
            var ancestor = tile
            while true {
                guard branches.insert(ancestor).inserted else { break }
                guard ancestor.z > 0, let parent = ancestor.findParentTile(atZoom: ancestor.z - 1) else { break }
                ancestor = parent
            }
        }
        func append(_ tile: Tile, slot: VisibleTile) {
            guard let entry = resident[tile] else { return }
            let placeIn = VisibleTile(tile: tile, worldWrap: slot.worldWrap)
            guard seen.insert(placeIn).inserted else { return }
            plan.placements.append(RasterTilePlacement(key: entry.key, texture: entry.texture, placeIn: placeIn, slot: slot))
        }

        /// Whether the resident descendants of `tile` cover it whole,
        /// placing them as it goes.
        func placeDescendants(of tile: Tile, slot: VisibleTile) -> Bool {
            if resident[tile] != nil, isPlaceable(tile) {
                append(tile, slot: slot)
                return true
            }
            guard branches.contains(tile) else { return false }
            var complete = true
            for child in children(of: tile) {
                complete = placeDescendants(of: child, slot: slot) && complete
            }
            return complete
        }

        for target in targets {
            let tile = target.tile
            if placeDescendants(of: tile, slot: target) {
                continue
            }
            var covered = false
            for zoom in stride(from: tile.z - 1, through: (floorZoom ?? -1) + 1, by: -1) {
                guard let ancestor = tile.findParentTile(atZoom: zoom) else { break }
                if resident[ancestor] != nil, isPlaceable(ancestor) {
                    append(ancestor, slot: target)
                    covered = true
                    break
                }
            }
            if covered == false {
                plan.uncovered.append(target)
            }
        }
        return plan
    }

    private static func children(of tile: Tile) -> [Tile] {
        let x = tile.x * 2
        let y = tile.y * 2
        let z = tile.z + 1
        return [Tile(x: x, y: y, z: z), Tile(x: x + 1, y: y, z: z),
                Tile(x: x, y: y + 1, z: z), Tile(x: x + 1, y: y + 1, z: z)]
    }
}

// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ModelTileFormat

/// Decides which level of detail a frame shows and which model tiles it
/// draws while the tiles of that level are still on their way.
///
/// The level is the camera zoom's (`ModelArchiveSettings.minimumZoom`,
/// `mediumDetailZoom`, `highDetailZoom`), one for the whole frame. The
/// frame asks the store for the tiles of that level alone. Until they are
/// loaded the ground keeps the models it had: a wanted tile still on its
/// way is drawn as the loaded tile of a coarser level it lies in, or as
/// the loaded tiles of a finer level that lie in it, and the swap is one
/// frame, with no frame of bare ground and none of a model drawn twice.
///
/// No ground is drawn twice because the levels are a pyramid: a tile holds
/// the models of the tiles under it and no others (`ModelTileDetail`). So
/// a coarser tile standing in for one wanted tile stands in for every
/// wanted tile under it, the loaded ones among them, until all of them are
/// in, and then gives way to them at once.
///
/// Pure functions over tiles, with no mesh and no store: the subsystem
/// hands in what the store answered.
enum ModelTilePlanner {
    typealias WantedTile = ModelTileRenderSubsystem.WantedTile

    /// What the store says of a wanted tile.
    enum TileState {
        /// On the GPU.
        case ready
        /// On its way.
        case pending
        /// Not coming this frame: the archive has no models there, or the
        /// tile failed and waits out its retry.
        case absent
    }

    struct Plan: Equatable {
        /// The tiles the frame draws, each in its copy of the world: the
        /// wanted ones that are loaded, and the tiles of other levels
        /// drawn in place of the ones that are not.
        var drawn: [WantedTile] = []
        /// The wanted tiles still on their way with nothing drawn in
        /// their place: the map's buildings under them wait
        /// (`ModelTileFrameState.pendingTiles`).
        var waiting: Set<Tile> = []
    }

    /// The level of detail at a camera zoom. `current` is the level the
    /// last frame showed: the camera has to go `detailSwitchMargin` back
    /// under a level's zoom before the level before it returns, so a
    /// camera resting on that zoom does not swap the two with every small
    /// move. Below `minimumZoom` the answer is the level that zoom shows:
    /// its tiles are the ones to have loaded when the camera arrives.
    static func detail(atZoom zoom: Double,
                       current: ModelTileDetail?,
                       settings: ImmersiveMapSettings.ModelArchiveSettings) -> ModelTileDetail {
        func level(_ zoom: Double) -> ModelTileDetail {
            if zoom >= settings.highDetailZoom { return .high }
            if zoom >= settings.mediumDetailZoom { return .medium }
            return .low
        }
        let zoom = max(zoom, settings.minimumZoom)
        let reached = level(zoom)
        guard let current else { return reached }
        if reached > current { return reached }
        let kept = level(zoom + max(settings.detailSwitchMargin, 0))
        return kept < current ? kept : current
    }

    /// The zoom of the tiles to ask for at a level: the level's own, or of
    /// the nearest level the archive holds when it was baked without this
    /// one (`missingZooms`, what the store has found so far), a finer one
    /// before a coarser. Nil for an archive with no level at all.
    static func tileZoom(of detail: ModelTileDetail, missingZooms: Set<Int>) -> Int? {
        let finer = ModelTileDetail.allCases.filter { $0 >= detail }
        let coarser = ModelTileDetail.allCases.filter { $0 < detail }.reversed()
        return (finer + coarser).map(\.tileZoom).first { missingZooms.contains($0) == false }
    }

    /// The frame's draws. `wanted` are the tiles the frame asked the store
    /// for, all of one level's zoom, and `state` the store's answer for
    /// each. `holdIfLoaded` says whether a tile of another level is on the
    /// GPU, and holds it for the frame if so (`ModelTileStore.heldMesh`):
    /// nothing is loaded for a stand-in.
    static func plan(wanted: [WantedTile],
                     state: (Tile) -> TileState,
                     holdIfLoaded: (Tile) -> Bool) -> Plan {
        var plan = Plan()
        guard let zoom = wanted.first?.tile.z else { return plan }
        let coarsestZoom = min(ModelTileDetail.low.tileZoom, zoom)
        let finestZoom = max(ModelTileDetail.high.tileZoom, zoom)

        /// The loaded tiles of the finer levels inside a tile that is not
        /// loaded, the nearest level first. False when there are none.
        func drawFiner(under node: WantedTile) -> Bool {
            guard node.tile.z < finestZoom else { return false }
            var drewAny = false
            for dy in 0...1 {
                for dx in 0...1 {
                    let child = WantedTile(tile: Tile(x: node.tile.x * 2 + dx, y: node.tile.y * 2 + dy, z: node.tile.z + 1),
                                           worldWrap: node.worldWrap)
                    if holdIfLoaded(child.tile) {
                        plan.drawn.append(child)
                        drewAny = true
                    } else if drawFiner(under: child) {
                        drewAny = true
                    }
                }
            }
            return drewAny
        }

        /// The draws over the ground of `node`, a tile of the wanted zoom
        /// or a coarser tile the wanted `members` lie in.
        func draw(_ node: WantedTile, members: [WantedTile]) {
            if node.tile.z == zoom {
                switch state(node.tile) {
                case .ready:
                    plan.drawn.append(node)
                case .pending:
                    if drawFiner(under: node) == false {
                        plan.waiting.insert(node.tile)
                    }
                case .absent:
                    break
                }
                return
            }
            // Every wanted tile here has its answer: they draw, and a
            // coarser tile over them has nothing left to stand in for.
            if members.allSatisfy({ state($0.tile) != .pending }) {
                plan.drawn.append(contentsOf: members.filter { state($0.tile) == .ready })
                return
            }
            if holdIfLoaded(node.tile) {
                plan.drawn.append(node)
                return
            }
            for (child, childMembers) in groups(of: members, atZoom: node.tile.z + 1) {
                draw(child, members: childMembers)
            }
        }

        for (root, members) in groups(of: wanted, atZoom: coarsestZoom) {
            draw(root, members: members)
        }
        return plan
    }

    /// The tiles grouped by the tile of `zoom` each lies in, in its copy
    /// of the world, the groups in the order their first tile came in.
    private static func groups(of tiles: [WantedTile], atZoom zoom: Int) -> [(WantedTile, [WantedTile])] {
        var order: [WantedTile] = []
        var members: [WantedTile: [WantedTile]] = [:]
        for tile in tiles {
            guard let parent = tile.tile.findParentTile(atZoom: zoom) else { continue }
            let key = WantedTile(tile: parent, worldWrap: tile.worldWrap)
            if members[key] == nil {
                order.append(key)
            }
            members[key, default: []].append(tile)
        }
        return order.map { ($0, members[$0] ?? []) }
    }
}

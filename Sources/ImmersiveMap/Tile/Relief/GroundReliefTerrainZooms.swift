// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Which terrain tiles the ground reads this frame: the zoom each band of
/// the frame's ring rules reads its terrain at (`FlatRingRule
/// .terrainZoomDrop`, resolved into `FlatRingBand.terrainZoom`), and the
/// map the camera flies over (`GroundReliefSettings.cameraTerrainZoom`).
/// Made by the store from the frame's bands (`GroundReliefStore.setBands`)
/// and asked by every draw that reads the terrain and by the frame's
/// demand (`GroundReliefDemand`), so what is drawn and what is loaded
/// agree.
///
/// The terrain is the ring's, not the tile's: whatever stands in a ring's
/// slot, the tile itself or a stand-in while it loads, is raised by the
/// same terrain, so a tile landing changes the fills and never the
/// ground's shape, and the whole ring moves to the next terrain at once,
/// at the zoom crossing, as its tiles do. A terrain tile finer than the
/// ground tile cannot raise it (four terrain tiles under one ground tile),
/// so a coarser tile reads the terrain of its own address instead
/// (`terrainTile(for:targetZoom:)`).
struct GroundReliefTerrainZooms: Equatable, Sendable {
    /// The zoom of the camera's map (`GroundReliefSettings.cameraTerrainZoom`).
    let cameraZoom: Int
    /// The finest zoom the ground's vertices rise by
    /// (`GroundReliefSettings.displacementMaximumZoom`): a ring's terrain
    /// finer than it shades the slopes, and the ground displaces by this
    /// zoom's tile.
    let displacementMaximumZoom: Int
    /// The terrain zoom by target zoom, the frame's bands': where two bands
    /// share a zoom, the nearer one's.
    let terrainZoomByTargetZoom: [Int: Int]

    init(cameraZoom: Int, displacementMaximumZoom: Int = 10, bands: [FlatRingBand] = []) {
        self.cameraZoom = max(0, cameraZoom)
        self.displacementMaximumZoom = max(0, displacementMaximumZoom)
        var byZoom: [Int: Int] = [:]
        for band in bands where byZoom[band.zoom] == nil {
            byZoom[band.zoom] = max(0, band.terrainZoom)
        }
        self.terrainZoomByTargetZoom = byZoom
    }

    /// The zoom a ring of `zoom` reads its terrain at: its band's, or its
    /// own for a zoom the frame has no band for (a stand-in coarser than
    /// every band, a store asked outside a frame). Past that the reads
    /// fall to the finest coarser terrain in
    /// (`GroundReliefFrame.relief(for:terrainZoom:)`).
    func terrainZoom(forTargetZoom zoom: Int) -> Int {
        terrainZoomByTargetZoom[zoom] ?? max(zoom, 0)
    }

    /// The terrain tile a ground tile in a ring of `targetZoom` shades its
    /// slopes by: the ring's terrain over the tile, or the tile's own
    /// address when that is coarser.
    func terrainTile(for tile: Tile, targetZoom: Int) -> Tile {
        tile.findParentTile(atZoom: max(min(terrainZoom(forTargetZoom: targetZoom), tile.z), 0)) ?? tile
    }

    /// The zoom a ring of `zoom` displaces its ground by: the ring's
    /// terrain zoom, no finer than `displacementMaximumZoom`.
    func displacementZoom(forTargetZoom zoom: Int) -> Int {
        min(terrainZoom(forTargetZoom: zoom), displacementMaximumZoom)
    }

    /// The terrain tile a ground tile in a ring of `targetZoom` displaces
    /// its grid by: `terrainTile(for:targetZoom:)` or its ancestor at the
    /// displacement's zoom.
    func displacementTile(for tile: Tile, targetZoom: Int) -> Tile {
        tile.findParentTile(atZoom: max(min(displacementZoom(forTargetZoom: targetZoom), tile.z), 0)) ?? tile
    }

    /// The bands as the panel's status line reads them: target zoom to
    /// terrain zoom, nearest first.
    var statusText: String {
        terrainZoomByTargetZoom.sorted { $0.key > $1.key }
            .map { "z\($0.key)→z\($0.value)" }
            .joined(separator: " ")
    }
}

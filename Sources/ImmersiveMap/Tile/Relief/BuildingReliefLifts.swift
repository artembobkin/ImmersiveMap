// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The buildings' lifts over the ground relief: for each drawn building
/// placement, the terrain's height under each volume's anchor, in the
/// terrain's metres, as a buffer the extruded vertex stage reads by the
/// volume's ordinal (TileExtruded.metal, `ExtrudedVertexIn.buildingOrdinal`).
/// Buildings on a slope stand level at the height of their anchor, which
/// the ground round them rises above and sinks below. Metres, not world
/// units, which change with the zoom, and not as drawn, which changes with
/// the relief's fade: the drawer binds the units a metre rises by this
/// frame beside them.
///
/// A tile's lifts are made once, when its terrain arrives or changes, and
/// kept while the tile draws with the same terrain. The tile is named by
/// its object's identity, and the entry carries the tile's address as
/// well, so a tile allocated where a released one was is not handed the
/// old lifts.
final class BuildingReliefLifts {
    private var buffersByTile: [ObjectIdentifier: (tile: Tile, terrain: ObjectIdentifier, revision: UInt64, buffer: MTLBuffer)] = [:]

    /// Lets go of every tile's lifts.
    func evict() {
        buffersByTile.removeAll()
    }

    /// The lifts of each placement, index-aligned with `placements`: nil
    /// for one not drawn (`drawnKeys` nil), with no buildings, or whose
    /// terrain is not in. With no store, every entry is nil and the cache
    /// is let go.
    func update(placements: [PlaceTile],
                drawnKeys: [VisibleTile?],
                store: GroundReliefStore?,
                device: MTLDevice) -> [MTLBuffer?] {
        guard let store else {
            buffersByTile.removeAll()
            return Array(repeating: nil, count: placements.count)
        }
        var lifts: [MTLBuffer?] = []
        lifts.reserveCapacity(placements.count)
        var kept: [ObjectIdentifier: (tile: Tile, terrain: ObjectIdentifier, revision: UInt64, buffer: MTLBuffer)] = [:]
        for (placement, key) in zip(placements, drawnKeys) {
            let metalTile = placement.metalTile
            let anchors = metalTile.tileBuffers.extruded.buildingAnchors
            guard key != nil, anchors.isEmpty == false,
                  let relief = store.relief(for: metalTile.tile, targetZoom: placement.placeIn.z) else {
                lifts.append(nil)
                continue
            }
            let tileIdentity = ObjectIdentifier(metalTile)
            let terrainIdentity = ObjectIdentifier(relief.terrain)
            // A weld of the terrain's edges (`GroundReliefTile.revision`)
            // moves the buildings by the edges with it.
            if let cached = buffersByTile[tileIdentity],
               cached.terrain == terrainIdentity,
               cached.revision == relief.terrain.revision,
               cached.tile == metalTile.tile,
               cached.buffer.length == anchors.count * MemoryLayout<Float>.stride {
                kept[tileIdentity] = cached
                lifts.append(cached.buffer)
                continue
            }
            var metres = [Float](repeating: 0, count: anchors.count)
            for (index, anchor) in anchors.enumerated() {
                // The anchor is render space (y up), the terrain's v grows
                // from the north edge.
                let uv = SIMD2<Float>(anchor.x, TileCoordinateSpace.tileExtent - anchor.y) / TileCoordinateSpace.tileExtent
                metres[index] = relief.metres(atTileUV: uv)
            }
            guard let buffer = metres.withUnsafeBytes({ bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }) else {
                lifts.append(nil)
                continue
            }
            kept[tileIdentity] = (metalTile.tile, terrainIdentity, relief.terrain.revision, buffer)
            lifts.append(buffer)
        }
        buffersByTile = kept
        return lifts
    }
}

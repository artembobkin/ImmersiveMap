// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The terrain tiles the frame stopped reading, kept for a frame that
/// reads them again (`GroundReliefStore.request(tiles:)`), up to
/// `capacityBytes` (`GroundReliefSettings.releasedCacheBytes`), the oldest
/// released let go first. A tile asked for again comes back from here
/// without a load. Not thread-safe: the store calls it under its lock.
struct GroundReliefReleasedCache {
    let capacityBytes: Int
    private var terrains: [Tile: GroundReliefTile] = [:]
    /// The tiles in the order they were released, oldest first.
    private var order: [Tile] = []
    private(set) var bytes = 0

    init(capacityBytes: Int) {
        self.capacityBytes = max(0, capacityBytes)
    }

    var count: Int { terrains.count }

    /// The tiles kept, for what is computed again over every tile in (the
    /// occlusion of the sky under a new key).
    var all: [(tile: Tile, terrain: GroundReliefTile)] {
        terrains.map { (tile: $0.key, terrain: $0.value) }
    }

    /// Keeps a tile the frame stopped reading, the oldest kept let go past
    /// the capacity. A tile that alone costs more than the capacity is not
    /// kept.
    mutating func keep(_ tile: Tile, terrain: GroundReliefTile) {
        guard capacityBytes > 0, terrain.costInBytes <= capacityBytes else { return }
        if terrains.updateValue(terrain, forKey: tile) == nil {
            bytes += terrain.costInBytes
        } else {
            order.removeAll { $0 == tile }
        }
        order.append(tile)
        while bytes > capacityBytes, let oldest = order.first {
            order.removeFirst()
            if let gone = terrains.removeValue(forKey: oldest) {
                bytes -= gone.costInBytes
            }
        }
    }

    /// A tile out of the cache, if it is there.
    mutating func take(_ tile: Tile) -> GroundReliefTile? {
        guard let terrain = terrains.removeValue(forKey: tile) else { return nil }
        bytes -= terrain.costInBytes
        order.removeAll { $0 == tile }
        return terrain
    }

    mutating func removeAll() {
        terrains.removeAll()
        order.removeAll()
        bytes = 0
    }
}

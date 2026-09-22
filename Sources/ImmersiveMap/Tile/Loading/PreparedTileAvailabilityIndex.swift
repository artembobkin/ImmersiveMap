// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Which tiles of one prepared cache directory have a `.ptile` on disk,
/// each with the entry's last access date, so an entry the TTL has expired
/// reads as absent before the prune sweep removes it. Written on the disk
/// cache's serial IO queue as files land and leave, read on the frame path
/// by the demand planner, which asks it for a loading target's nearest
/// ancestor that would come back from disk without a network request. The
/// lock makes the reads consistent and never waits on file IO.
///
/// A hint, never a guarantee: the loader validates every entry it reads,
/// and a stale hint costs one ancestor demanded that then loads the slow
/// way, which every ancestor once did.
final class PreparedTileAvailabilityIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var lastAccessDatesByTile: [Tile: Date] = [:]
    private var timeToLive: TimeInterval

    init(timeToLive: TimeInterval) {
        self.timeToLive = timeToLive
    }

    /// Present and not expired.
    func contains(_ tile: Tile, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastAccessDate = lastAccessDatesByTile[tile] else {
            return false
        }
        return now.timeIntervalSince(lastAccessDate) <= timeToLive
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return lastAccessDatesByTile.count
    }

    func insert(_ tile: Tile, lastAccessDate: Date) {
        lock.lock()
        lastAccessDatesByTile[tile] = lastAccessDate
        lock.unlock()
    }

    func remove(_ tile: Tile) {
        lock.lock()
        lastAccessDatesByTile.removeValue(forKey: tile)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        lastAccessDatesByTile.removeAll()
        lock.unlock()
    }

    func replaceAll(_ entries: [Tile: Date]) {
        lock.lock()
        lastAccessDatesByTile = entries
        lock.unlock()
    }

    func updateTimeToLive(_ timeToLive: TimeInterval) {
        lock.lock()
        self.timeToLive = timeToLive
        lock.unlock()
    }

    /// The tile a prepared cache file name stands for: `z_x_y.ptile`. Nil
    /// for the `.ptgeo` blob, a staged `.tmp-<UUID>` file, and anything else
    /// that shares the directory.
    static func tile(forPreparedTileFileName fileName: String) -> Tile? {
        tile(forFileName: fileName, suffix: ".ptile")
    }

    /// The tile a blob file name stands for: `z_x_y.ptgeo`. Nil for anything
    /// else, staged `.tmp-<UUID>` files included.
    static func tile(forPreparedBlobFileName fileName: String) -> Tile? {
        tile(forFileName: fileName, suffix: ".ptgeo")
    }

    private static func tile(forFileName fileName: String, suffix: String) -> Tile? {
        guard fileName.hasSuffix(suffix) else {
            return nil
        }
        let components = fileName.dropLast(suffix.count).split(separator: "_", omittingEmptySubsequences: false)
        guard components.count == 3,
              let z = Int(components[0]),
              let x = Int(components[1]),
              let y = Int(components[2]),
              z >= 0, x >= 0, y >= 0 else {
            return nil
        }
        return Tile(x: x, y: y, z: z)
    }
}

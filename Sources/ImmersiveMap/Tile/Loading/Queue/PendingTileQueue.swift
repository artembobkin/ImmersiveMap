// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// The tiles that wait for a free load slot, in the order they were asked
/// for: each tile once, and no more of them than `capacity`.
///
/// When the queue is full, a new tile takes the place of the one that has
/// waited longest, which leaves the queue. That is the queue's purpose and
/// not a failure: under a fast pan the oldest requests are the ones the
/// screen has already left, and loading them would hold the slots the
/// tiles in view need. A tile that left this way can be enqueued again.
///
/// The queue holds the backlog of one request. The loader
/// (`ImmersiveMapNeedsTile`) clears it at every new request and enqueues
/// that request's tiles over again, so a tile that is still wanted comes
/// back with the next request and one that is not is never loaded.
///
/// Not thread-safe: the loader reaches it on its state queue alone.
final class PendingTileQueue {
    /// A ring: `head` is the tile that has waited longest.
    private var ring: [Tile?]
    private var head = 0
    private var count = 0
    /// The tiles in the ring, to refuse a tile that already waits.
    private var waiting: Set<Tile> = []

    /// A capacity below one is taken as one.
    init(capacity: Int) {
        ring = [Tile?](repeating: nil, count: max(1, capacity))
    }

    var isEmpty: Bool {
        count == 0
    }

    /// Puts `tile` at the end of the queue. A tile that already waits keeps
    /// its place. On a full queue the tile that has waited longest leaves
    /// to make room, and is returned.
    @discardableResult
    func enqueue(_ tile: Tile) -> Tile? {
        guard waiting.insert(tile).inserted else {
            return nil
        }
        var dropped: Tile?
        if count == ring.count {
            dropped = ring[head]
            if let dropped {
                waiting.remove(dropped)
            }
            head = (head + 1) % ring.count
            count -= 1
        }
        ring[(head + count) % ring.count] = tile
        count += 1
        return dropped
    }

    /// The tile that has waited longest, taken out of the queue.
    func dequeue() -> Tile? {
        guard count > 0, let tile = ring[head] else {
            return nil
        }
        ring[head] = nil
        head = (head + 1) % ring.count
        count -= 1
        waiting.remove(tile)
        return tile
    }

    func clear() {
        ring = [Tile?](repeating: nil, count: ring.count)
        head = 0
        count = 0
        waiting.removeAll(keepingCapacity: true)
    }
}

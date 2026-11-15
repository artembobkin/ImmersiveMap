// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

final class DeduplicatedTilesFIFO {
    private let fifo: FIFOStack<Tile>
    private var enqueuedTiles: Set<Tile> = []

    init(capacity: Int) {
        self.fifo = FIFOStack(capacity: capacity)
    }

    @discardableResult
    func enqueue(_ tile: Tile) -> Bool {
        guard enqueuedTiles.insert(tile).inserted else {
            return false
        }
        fifo.push(tile)
        return true
    }

    func dequeue() -> Tile? {
        guard let tile = fifo.pop() else {
            return nil
        }
        enqueuedTiles.remove(tile)
        return tile
    }

    func clear() {
        fifo.clear()
        enqueuedTiles.removeAll()
    }
}

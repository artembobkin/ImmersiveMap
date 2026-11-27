// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The queue of tiles waiting for a load slot: first in first out, each
/// tile once, and on a full queue the tile that has waited longest leaves.
final class PendingTileQueueTests: XCTestCase {
    private func tile(_ x: Int) -> Tile {
        Tile(x: x, y: 0, z: 10)
    }

    private func drain(_ queue: PendingTileQueue) -> [Tile] {
        var tiles: [Tile] = []
        while let tile = queue.dequeue() {
            tiles.append(tile)
        }
        return tiles
    }

    func testTilesLeaveInTheOrderTheyCame() {
        let queue = PendingTileQueue(capacity: 4)
        XCTAssertTrue(queue.isEmpty)
        for x in 0..<3 {
            XCTAssertNil(queue.enqueue(tile(x)), "A queue with room drops nothing")
        }

        XCTAssertFalse(queue.isEmpty)
        XCTAssertEqual(drain(queue), [tile(0), tile(1), tile(2)])
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.dequeue())
    }

    func testATileThatAlreadyWaitsKeepsItsPlace() {
        let queue = PendingTileQueue(capacity: 4)
        queue.enqueue(tile(0))
        queue.enqueue(tile(1))
        XCTAssertNil(queue.enqueue(tile(0)))

        XCTAssertEqual(drain(queue), [tile(0), tile(1)])
    }

    func testAFullQueueDropsTheTileThatHasWaitedLongest() {
        let queue = PendingTileQueue(capacity: 3)
        for x in 0..<3 {
            queue.enqueue(tile(x))
        }

        XCTAssertEqual(queue.enqueue(tile(3)), tile(0), "The oldest tile makes room and is named")
        XCTAssertEqual(queue.enqueue(tile(4)), tile(1))
        XCTAssertEqual(drain(queue), [tile(2), tile(3), tile(4)])
    }

    /// The tile that was dropped is no longer counted as waiting, whether or
    /// not the loader has cleared the queue since.
    func testADroppedTileCanBeEnqueuedAgain() {
        let queue = PendingTileQueue(capacity: 2)
        queue.enqueue(tile(0))
        queue.enqueue(tile(1))
        XCTAssertEqual(queue.enqueue(tile(2)), tile(0))

        XCTAssertEqual(queue.enqueue(tile(0)), tile(1), "It takes a place again, at the end")
        XCTAssertEqual(drain(queue), [tile(2), tile(0)])
    }

    func testADequeuedTileCanBeEnqueuedAgain() {
        let queue = PendingTileQueue(capacity: 2)
        queue.enqueue(tile(0))
        XCTAssertEqual(queue.dequeue(), tile(0))

        queue.enqueue(tile(0))
        XCTAssertEqual(drain(queue), [tile(0)])
    }

    func testClearingForgetsEveryTile() {
        let queue = PendingTileQueue(capacity: 2)
        queue.enqueue(tile(0))
        queue.enqueue(tile(1))
        queue.clear()

        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.dequeue())
        queue.enqueue(tile(1))
        queue.enqueue(tile(0))
        XCTAssertEqual(drain(queue), [tile(1), tile(0)])
    }

    /// The ring wraps many times over and still hands the tiles out in order.
    func testTheOrderHoldsWhileTheRingWraps() {
        let queue = PendingTileQueue(capacity: 3)
        var expected: [Tile] = []
        for x in 0..<20 {
            queue.enqueue(tile(x))
            if x % 2 == 1, let next = queue.dequeue() {
                expected.append(next)
            }
        }

        XCTAssertEqual(expected, expected.sorted { $0.x < $1.x })
        XCTAssertEqual(Set(expected).count, expected.count, "No tile is handed out twice")
    }

    func testACapacityBelowOneIsOne() {
        let queue = PendingTileQueue(capacity: 0)
        queue.enqueue(tile(0))
        XCTAssertEqual(queue.enqueue(tile(1)), tile(0))
        XCTAssertEqual(drain(queue), [tile(1)])
    }
}

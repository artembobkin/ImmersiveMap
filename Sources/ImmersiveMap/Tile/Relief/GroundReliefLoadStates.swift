// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// How the terrain store's loads go (`GroundReliefStore`): which tiles are
/// on their way and since when, which failed and when they are tried
/// again, which the source does not have, and how many load slots are
/// taken. The bookkeeping alone: no tile, no task and no lock, which stay
/// the store's, so the rules of the retries and the slots are plain
/// values a test reads without a device.
///
/// A tile the source does not have (`missing`) is remembered for good,
/// and its ancestor is wanted in its place. One that could not be fetched
/// is asked again after a pause that grows with each failure, and counts
/// as unavailable (`isUnavailable`) from `unavailableAfterAttempts`
/// failures on, while the retries go on behind.
struct GroundReliefLoadStates {
    static let retryBaseDelay: TimeInterval = 5
    static let retryMaximumDelay: TimeInterval = 60
    /// How many attempts a load fails before its tile counts as
    /// unavailable (`isUnavailable`): the planner then places what rises by
    /// it flat instead of waiting, and the retries go on behind, so the
    /// ground rises once the source answers. Two: the first failure may be
    /// a dropped connection, the second one `retryBaseDelay` later says
    /// the source is out of reach.
    static let unavailableAfterAttempts = 2

    enum State {
        case loading(failedAttempts: Int)
        case failed(attempts: Int, retryAt: TimeInterval)
    }

    /// How many terrain tiles load at once
    /// (`GroundReliefSettings.maximumConcurrentLoads`).
    let maximumConcurrentLoads: Int
    private(set) var statesByTile: [Tile: State] = [:]
    /// When each load started, for the debug panel.
    private(set) var startedAt: [Tile: TimeInterval] = [:]
    private(set) var activeLoads = 0
    /// The tiles the source does not have.
    private(set) var missing: Set<Tile> = []

    init(maximumConcurrentLoads: Int) {
        self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
    }

    func isMissing(_ tile: Tile) -> Bool {
        missing.contains(tile)
    }

    /// Whether a tile cannot come for now: the source has no such tile, or
    /// has not answered for it `unavailableAfterAttempts` times.
    func isUnavailable(_ tile: Tile) -> Bool {
        if missing.contains(tile) {
            return true
        }
        if case .failed(let attempts, _) = statesByTile[tile], attempts >= Self.unavailableAfterAttempts {
            return true
        }
        return false
    }

    /// The wanted tiles to load now, nearest first, while slots are free:
    /// neither in (`isLoaded`) nor on their way, and a failed one only
    /// once its pause is out. Each is counted as loading from here, with
    /// the failures it has behind it.
    mutating func start(wanted: [Tile], isLoaded: (Tile) -> Bool, now: TimeInterval) -> [Tile] {
        var started: [Tile] = []
        for tile in wanted where activeLoads < maximumConcurrentLoads {
            guard isLoaded(tile) == false else { continue }
            switch statesByTile[tile] {
            case .loading:
                continue
            case .failed(let attempts, let retryAt):
                if now >= retryAt {
                    begin(tile, failedAttempts: attempts, now: now)
                    started.append(tile)
                }
            case nil:
                begin(tile, failedAttempts: 0, now: now)
                started.append(tile)
            }
        }
        return started
    }

    private mutating func begin(_ tile: Tile, failedAttempts: Int, now: TimeInterval) {
        statesByTile[tile] = .loading(failedAttempts: failedAttempts)
        startedAt[tile] = now
        activeLoads += 1
    }

    /// A load that ended with an answer: the heights, or `missing` for a
    /// tile the source does not have.
    mutating func finish(_ tile: Tile, missing isMissing: Bool) {
        statesByTile.removeValue(forKey: tile)
        startedAt.removeValue(forKey: tile)
        activeLoads -= 1
        if isMissing {
            missing.insert(tile)
        }
    }

    /// A load that failed: its tile waits out a pause that doubles with
    /// each failure, up to `retryMaximumDelay`. Returns the pause and
    /// whether the tile has just turned unavailable.
    mutating func fail(_ tile: Tile, now: TimeInterval) -> (delay: TimeInterval, becameUnavailable: Bool) {
        var attempts = 1
        if case .loading(let failedAttempts) = statesByTile[tile] {
            attempts = failedAttempts + 1
        }
        let delay = min(Self.retryMaximumDelay, Self.retryBaseDelay * pow(2, Double(attempts - 1)))
        statesByTile[tile] = .failed(attempts: attempts, retryAt: now + delay)
        startedAt.removeValue(forKey: tile)
        activeLoads -= 1
        return (delay, attempts == Self.unavailableAfterAttempts)
    }

    /// The wanted tiles still to come: on their way or queued, and a failed
    /// one whose retry is due. Not a resident one, not one the source has
    /// no tile for, and not one waiting out its retry.
    func pendingCount(wanted: [Tile], isLoaded: (Tile) -> Bool, now: TimeInterval) -> Int {
        var pending = 0
        for tile in wanted where isLoaded(tile) == false && missing.contains(tile) == false {
            switch statesByTile[tile] {
            case .loading, nil:
                pending += 1
            case .failed(_, let retryAt):
                if now >= retryAt { pending += 1 }
            }
        }
        return pending
    }

    var failedCount: Int {
        statesByTile.values.reduce(0) { count, state in
            if case .failed = state { return count + 1 }
            return count
        }
    }
}

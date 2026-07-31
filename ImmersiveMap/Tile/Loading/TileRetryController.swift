// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

// Business purpose:
// Centrally manages tile-download retry windows so the map does not create a
// request storm under persistent errors.
// The controller keeps per-tile backoff and a global cooldown (e.g. for auth/rate-limit),
// and provides a single decision: whether a specific tile may be requested again right now.
// The global cooldown is an emergency fuse for systemic failures:
// on 401/403 (authorization problem) and 429 (overload/rate-limit) it temporarily
// throttles the whole tile-request stream instead of hammering the API tile by tile.
enum TileRetryFailureReason {
    case download(TileDownloader.DownloadFailure)
    case parseFailed
}

final class TileRetryController {
    struct Policy {
        var baseBackoff: TimeInterval
        var maxBackoff: TimeInterval
        var parseFailureCooldown: TimeInterval
        var notFoundCooldown: TimeInterval
        var missingAuthorizationTokenCooldown: TimeInterval
        var authCooldown: TimeInterval
        var genericClientCooldown: TimeInterval
        var rateLimitCooldown: TimeInterval
        var globalAuthCooldown: TimeInterval
        var globalRateLimitCooldown: TimeInterval
        var maxExponent: Int

        static let `default` = Policy(baseBackoff: 0.5,
                                      maxBackoff: 30.0,
                                      parseFailureCooldown: 120.0,
                                      notFoundCooldown: 600.0,
                                      missingAuthorizationTokenCooldown: 30.0,
                                      authCooldown: 30.0,
                                      genericClientCooldown: 60.0,
                                      rateLimitCooldown: 5.0,
                                      globalAuthCooldown: 15.0,
                                      globalRateLimitCooldown: 2.0,
                                      maxExponent: 6)
    }

    private struct RetryState {
        let failureCount: Int
        let nextRetryAt: Date
    }

    private var retryStateByTile: [Tile: RetryState] = [:]
    private var globalRetryBlockedUntil: Date?
    private let policy: Policy
    private let nowProvider: () -> Date

    // Creates a retry-policy controller with a current-time source
    // (real time in production, a controllable clock in tests).
    init(policy: Policy, now: @escaping () -> Date = Date.init) {
        self.policy = policy
        self.nowProvider = now
    }

    // Returns whether the request for a specific tile must be blocked right now,
    // considering the global cooldown and the tile's individual backoff.
    func shouldBlock(tile: Tile) -> Bool {
        let now = nowProvider()
        clearExpiredGlobalBlockIfNeeded(now: now)

        if let blockedUntil = globalRetryBlockedUntil, now < blockedUntil {
            return true
        }
        if let retryState = retryStateByTile[tile], now < retryState.nextRetryAt {
            return true
        }
        return false
    }

    // Records a successful tile download/parse and clears its retry state.
    func registerSuccess(for tile: Tile) {
        retryStateByTile.removeValue(forKey: tile)
        clearExpiredGlobalBlockIfNeeded(now: nowProvider())
    }

    // Registers a failed tile attempt, computes the next retry window,
    // and extends the global cooldown if needed.
    func registerFailure(for tile: Tile, reason: TileRetryFailureReason) {
        let now = nowProvider()
        let failureCount = retryStateByTile[tile]?.failureCount ?? 0
        let retryDelay = retryDelay(for: reason, failureCount: failureCount)
        let nextRetryAt = now.addingTimeInterval(retryDelay)
        retryStateByTile[tile] = RetryState(failureCount: failureCount + 1, nextRetryAt: nextRetryAt)

        if let globalDelay = globalRetryDelay(for: reason) {
            let nextGlobalRetryAt = now.addingTimeInterval(globalDelay)
            if let currentGlobalBlockedUntil = globalRetryBlockedUntil {
                globalRetryBlockedUntil = max(currentGlobalBlockedUntil, nextGlobalRetryAt)
            } else {
                globalRetryBlockedUntil = nextGlobalRetryAt
            }
        }
    }

    // The nearest FUTURE moment when at least one blocked tile becomes
    // requestable again. Needed by the scheduler to wake the on-demand render
    // loop at backoff-window expiry: the controller itself is passive and holds
    // no timers. Already expired windows are ignored: their tiles are unblocked
    // and will be retried on the next frame, and an expired record (it lives
    // until registerSuccess/retainOnly) must not mask future windows of other
    // tiles. With an active global cooldown, returns its boundary -
    // no tile unblocks before it.
    func earliestNextRetryDate() -> Date? {
        let now = nowProvider()
        clearExpiredGlobalBlockIfNeeded(now: now)

        if let globalRetryBlockedUntil {
            return globalRetryBlockedUntil
        }
        return retryStateByTile.values.map(\.nextRetryAt).filter { $0 > now }.min()
    }

    // Keeps retry state only for the current tile set, so stale state
    // for tiles outside the current interest is not retained.
    func retainOnly(tiles: Set<Tile>) {
        retryStateByTile = retryStateByTile.filter { tiles.contains($0.key) }
        clearExpiredGlobalBlockIfNeeded(now: nowProvider())
    }

    // Fully clears retry state (per-tile and global cooldown).
    func reset() {
        retryStateByTile.removeAll()
        globalRetryBlockedUntil = nil
    }

    // Lifts the global block if its deadline has already passed.
    private func clearExpiredGlobalBlockIfNeeded(now: Date) {
        if let blockedUntil = globalRetryBlockedUntil, blockedUntil <= now {
            globalRetryBlockedUntil = nil
        }
    }

    // Picks the retry delay for a specific failure reason.
    private func retryDelay(for reason: TileRetryFailureReason, failureCount: Int) -> TimeInterval {
        switch reason {
        case .parseFailed:
            return policy.parseFailureCooldown
        case let .download(downloadFailure):
            switch downloadFailure {
            case .missingAuthorizationToken:
                return policy.missingAuthorizationTokenCooldown
            case .unauthorized, .forbidden:
                return policy.authCooldown
            case .notFound, .gone:
                return policy.notFoundCooldown
            case let .rateLimited(retryAfter):
                return max(retryAfter ?? 0, policy.rateLimitCooldown)
            case .client(_):
                return policy.genericClientCooldown
            case .server(_), .network, .nonHTTPResponse, .emptyBody:
                return exponentialBackoff(failureCount: failureCount)
            }
        }
    }

    // Returns the global cooldown delay for "global" errors
    // (e.g. auth/rate-limit), or nil if only per-tile backoff is needed.
    private func globalRetryDelay(for reason: TileRetryFailureReason) -> TimeInterval? {
        switch reason {
        case .parseFailed:
            return nil
        case let .download(downloadFailure):
            switch downloadFailure {
            case .missingAuthorizationToken, .unauthorized, .forbidden:
                return policy.globalAuthCooldown
            case let .rateLimited(retryAfter):
                return max(retryAfter ?? 0, policy.globalRateLimitCooldown)
            case .notFound, .gone, .server(_), .client(_), .nonHTTPResponse, .emptyBody, .network:
                return nil
            }
        }
    }

    // Exponential backoff for transient/network errors.
    private func exponentialBackoff(failureCount: Int) -> TimeInterval {
        let exponent = min(failureCount, policy.maxExponent)
        let delay = policy.baseBackoff * pow(2.0, Double(exponent))
        return min(delay, policy.maxBackoff)
    }
}

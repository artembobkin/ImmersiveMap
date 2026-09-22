// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct DebugOverlayHUDSnapshotStoreValue: Equatable {
    let version: UInt64
    let snapshot: DebugOverlayHUDSnapshot?
}

/// The frame's HUD snapshot on its way from the engine to the panel, plus a
/// live source for the tile list: frames publish a snapshot only when they
/// render and only as often as the throttle allows, so the last event of a
/// loading burst (the frame the landing tile itself requested) is often
/// the one no snapshot is built for, and the loop then sleeps. The panel's
/// timer asks the provider instead, and the rows never stay behind the
/// loader.
final class DebugOverlayHUDSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var version: UInt64 = 0
    private var snapshot: DebugOverlayHUDSnapshot?
    private var tileLoadingStatusProvider: (@Sendable () -> TileLoadingStatusSnapshot?)?

    /// The engine attaches its reporter when it is built and detaches it
    /// when discarded. Thread-safe like the rest of the store.
    func attachTileLoadingStatus(provider: (@Sendable () -> TileLoadingStatusSnapshot?)?) {
        lock.lock()
        tileLoadingStatusProvider = provider
        lock.unlock()
    }

    /// The reporter's state right now, or nil without a provider (no engine,
    /// or the debug panel is off and the engine keeps no reporter).
    func currentTileLoadingStatus() -> TileLoadingStatusSnapshot? {
        lock.lock()
        let provider = tileLoadingStatusProvider
        lock.unlock()
        return provider?()
    }

    /// The between-frames refresh: the snapshot the panel shows with its
    /// tile list read again from the reporter, or nil when there is nothing
    /// shown, no provider, or nothing moved since.
    func refreshedSnapshot(applying applied: DebugOverlayHUDSnapshot?) -> DebugOverlayHUDSnapshot? {
        guard let applied, let status = currentTileLoadingStatus() else {
            return nil
        }
        let refreshed = applied.replacingTileLoadingStatus(status)
        return refreshed == applied ? nil : refreshed
    }

    @discardableResult
    func publish(_ snapshot: DebugOverlayHUDSnapshot?) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        version &+= 1
        self.snapshot = snapshot
        return version
    }

    func consumeLatest(after consumedVersion: UInt64) -> DebugOverlayHUDSnapshotStoreValue? {
        lock.lock()
        defer { lock.unlock() }

        guard version != consumedVersion else {
            return nil
        }

        return DebugOverlayHUDSnapshotStoreValue(version: version,
                                                snapshot: snapshot)
    }
}

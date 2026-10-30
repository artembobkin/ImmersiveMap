// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

package struct DebugOverlayHUDSnapshotStoreValue: Equatable {
    package let version: UInt64
    package let snapshot: DebugOverlayHUDSnapshot?
}

/// The frame's HUD snapshot on its way from the engine to the panel, and
/// the panel's wishes on their way back. Every rendered frame publishes a
/// snapshot and the panel applies it in the same turn of the main thread
/// (`onSnapshotPublished`), so the numbers on the panel are the frame's
/// on screen. Between frames the loader goes on, and the on-demand loop
/// sleeps: the reporter says when its state moved
/// (`noteTileLoadingStatusChanged`), the store folds a burst of changes
/// into one hop to the main thread, and the panel reads the rows from the
/// provider, so the rows never stay behind the loader. The panel says
/// which content it shows (`requestedContent`), and a frame builds only
/// that.
package final class DebugOverlayHUDSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var version: UInt64 = 0
    private var snapshot: DebugOverlayHUDSnapshot?
    private var tileLoadingStatusProvider: (@Sendable () -> TileLoadingStatusSnapshot?)?
    private var content: DebugOverlayHUDContentRequest = .all
    private var isTileLoadingStatusRefreshScheduled = false

    /// The panel's hooks, set once by the panel's runtime and called on the
    /// main thread only: a frame's snapshot just published, and the
    /// loader's state moved between frames.
    package nonisolated(unsafe) var onSnapshotPublished: (@MainActor () -> Void)?
    package nonisolated(unsafe) var onTileLoadingStatusChanged: (@MainActor () -> Void)?

    package init() {}

    /// What the panel shows, for the frame to build: the panel sets it on
    /// a tab change, the engine reads it every frame.
    package var requestedContent: DebugOverlayHUDContentRequest {
        get {
            lock.lock()
            defer { lock.unlock() }
            return content
        }
        set {
            lock.lock()
            content = newValue
            lock.unlock()
        }
    }

    /// The reporter's word that its state moved, from the loader's threads:
    /// one hop to the main thread for a burst of changes, where the panel
    /// reads the rows again.
    package func noteTileLoadingStatusChanged() {
        lock.lock()
        let schedule = isTileLoadingStatusRefreshScheduled == false
        isTileLoadingStatusRefreshScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.isTileLoadingStatusRefreshScheduled = false
            self.lock.unlock()
            MainActor.assumeIsolated {
                self.onTileLoadingStatusChanged?()
            }
        }
    }

    /// The engine attaches its reporter when it is built and detaches it
    /// when discarded. Thread-safe like the rest of the store.
    package func attachTileLoadingStatus(provider: (@Sendable () -> TileLoadingStatusSnapshot?)?) {
        lock.lock()
        tileLoadingStatusProvider = provider
        lock.unlock()
    }

    /// The reporter's state right now, or nil without a provider (no engine,
    /// or the debug panel is off and the engine keeps no reporter).
    package func currentTileLoadingStatus() -> TileLoadingStatusSnapshot? {
        lock.lock()
        let provider = tileLoadingStatusProvider
        lock.unlock()
        return provider?()
    }

    /// The between-frames refresh: the snapshot the panel shows with its
    /// tile list read again from the reporter, or nil when there is nothing
    /// shown, no provider, or nothing moved since.
    package func refreshedSnapshot(applying applied: DebugOverlayHUDSnapshot?) -> DebugOverlayHUDSnapshot? {
        guard let applied, let status = currentTileLoadingStatus() else {
            return nil
        }
        let refreshed = applied.replacingTileLoadingStatus(status)
        return refreshed == applied ? nil : refreshed
    }

    @discardableResult
    package func publish(_ snapshot: DebugOverlayHUDSnapshot?) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        version &+= 1
        self.snapshot = snapshot
        return version
    }

    package func consumeLatest(after consumedVersion: UInt64) -> DebugOverlayHUDSnapshotStoreValue? {
        lock.lock()
        defer { lock.unlock() }

        guard version != consumedVersion else {
            return nil
        }

        return DebugOverlayHUDSnapshotStoreValue(version: version,
                                                snapshot: snapshot)
    }
}

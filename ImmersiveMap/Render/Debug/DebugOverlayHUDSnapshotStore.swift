// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct DebugOverlayHUDSnapshotStoreValue: Equatable {
    let version: UInt64
    let snapshot: DebugOverlayHUDSnapshot?
}

final class DebugOverlayHUDSnapshotStore {
    private let lock = NSLock()
    private var version: UInt64 = 0
    private var snapshot: DebugOverlayHUDSnapshot?

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

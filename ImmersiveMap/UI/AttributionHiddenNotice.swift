// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// One hidden-attribution warning per process: every map view constructed
/// with a hidden badge carries the same news, and the license obligation
/// belongs to the app, not to whichever view happened to appear first.
/// `@unchecked Sendable` for the same reason as `TileRateLimitNotice`:
/// the lock is the synchronization the compiler cannot see.
final class AttributionHiddenNotice: @unchecked Sendable {
    static let shared = AttributionHiddenNotice()

    private let lock = NSLock()
    private var didLog = false

    func shouldLog() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard didLog == false else {
            return false
        }
        didLog = true
        return true
    }

    /// Test hook: the notice is process wide, so a test that did not clear it
    /// would be decided by whichever test happened to run first.
    func reset() {
        lock.lock()
        defer {
            lock.unlock()
        }
        didLog = false
    }

    /// Pure decision, separated so tests need no host view: the badge is
    /// hidden or has nothing to draw, and the app has not declared that it
    /// shows the credit itself.
    static func isWarningWarranted(for settings: ImmersiveMapSettings) -> Bool {
        settings.attribution.isProvidedExternally == false
            && (settings.attribution.isVisible == false || settings.resolvedAttribution.isEmpty)
    }
}

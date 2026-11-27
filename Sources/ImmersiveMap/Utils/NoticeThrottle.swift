// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// Lets a warning through once per interval, however often its cause
/// repeats: a line a second while the user scrolls is noise, one line a
/// minute is the answer to "why is my map full of holes". One instance per
/// kind of news, held process wide by whoever logs it, since the cause (a
/// quota, a broken key, an unreadable archive) belongs to the app and not
/// to the object that happened to notice first.
/// `@unchecked Sendable` because the lock is the synchronisation the compiler
/// cannot see: the state is private and every path to it goes through `lock`.
final class NoticeThrottle: @unchecked Sendable {
    static let interval: TimeInterval = 60

    private let lock = NSLock()
    private var lastLoggedAt: Date?

    func shouldLog(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastLoggedAt, now.timeIntervalSince(last) < Self.interval {
            return false
        }
        lastLoggedAt = now
        return true
    }

    /// Test hook: the throttle is process wide, so a test that did not clear it
    /// would be decided by whichever test happened to run first.
    func reset() {
        lock.lock()
        lastLoggedAt = nil
        lock.unlock()
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Awaits a callback-style operation with a deadline: `start` is handed the
/// completion to call, and the await ends with the first of the callback's
/// value and the deadline (nil). A callback that arrives after the deadline
/// is ignored, and one that arrives twice resumes once. For operations
/// whose completion can fail to come at all (a driver that parks a request
/// forever), so a slot waiting on them is freed instead of held for good.
enum CallbackTimeout {
    static func await<Value: Sendable>(seconds: TimeInterval,
                                       start: (@escaping @Sendable (Value) -> Void) -> Void) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let once = OnceResumer(continuation)
            start { value in
                once.resume(value)
            }
            let nanoseconds = UInt64(max(seconds, 0) * 1_000_000_000)
            Task {
                try? await Task.sleep(nanoseconds: nanoseconds)
                once.resume(nil)
            }
        }
    }

    /// Resumes its continuation at most once, from whichever caller comes
    /// first.
    private final class OnceResumer<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value?, Never>?

        init(_ continuation: CheckedContinuation<Value?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Value?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }
}

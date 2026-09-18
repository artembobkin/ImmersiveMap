// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// A callback awaited with a deadline: its value when it comes in time,
/// nil when it never comes, and a late or repeated callback changes
/// nothing.
final class CallbackTimeoutTests: XCTestCase {
    func testTheValueComesThroughWhenTheCallbackIsInTime() async {
        let value = await CallbackTimeout.await(seconds: 1) { complete in
            complete(42)
        }
        XCTAssertEqual(value, 42)
    }

    func testACallbackThatNeverComesEndsInNilAtTheDeadline() async {
        let start = Date()
        let value: Int? = await CallbackTimeout.await(seconds: 0.05) { _ in }
        XCTAssertNil(value)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.04)
    }

    func testALateOrRepeatedCallbackIsIgnored() async {
        let late = LateCompletion()
        let value: Int? = await CallbackTimeout.await(seconds: 0.05) { complete in
            late.store(complete)
        }
        XCTAssertNil(value)
        late.fire(7)
        late.fire(8)

        let twice = await CallbackTimeout.await(seconds: 1) { complete in
            complete(1)
            complete(2)
        }
        XCTAssertEqual(twice, 1)
    }

    private final class LateCompletion: @unchecked Sendable {
        private var completion: (@Sendable (Int) -> Void)?

        func store(_ completion: @escaping @Sendable (Int) -> Void) {
            self.completion = completion
        }

        func fire(_ value: Int) {
            completion?(value)
        }
    }
}

// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// A renderer-owned resource that is created on first use.
///
/// Pin rendering already runs on its serialized render path, so this holder
/// intentionally has the same access assumptions and does not add locking.
final class LazyPinRenderResource<Value> {
    private var factory: (() -> Value)?
    private var storedValue: Value?

    init(factory: @escaping () -> Value) {
        self.factory = factory
    }

    var isInitialized: Bool {
        storedValue != nil
    }

    var existingValue: Value? {
        storedValue
    }

    var value: Value {
        if let storedValue {
            return storedValue
        }
        guard let factory else {
            preconditionFailure("Lazy pin render resource factory is unavailable.")
        }
        let value = factory()
        storedValue = value
        self.factory = nil
        return value
    }
}

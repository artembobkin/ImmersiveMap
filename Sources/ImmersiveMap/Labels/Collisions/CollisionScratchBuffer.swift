// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// A growable array of trivial values over manually managed memory, for the
/// collision solver's grid: subscripts and appends compile to a load or a
/// store with no bounds check, no uniqueness check and no exclusivity
/// enforcement, so the solve runs at the same speed whether or not the
/// optimizer is on. Only trivial types (no references) may be stored: the
/// memory is never destroyed element by element.
final class CollisionScratchBuffer<Element> {
    private(set) var pointer: UnsafeMutablePointer<Element>
    private(set) var count: Int = 0
    private(set) var capacity: Int

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
        self.pointer = UnsafeMutablePointer<Element>.allocate(capacity: self.capacity)
    }

    deinit {
        pointer.deallocate()
    }

    @inline(__always)
    subscript(index: Int) -> Element {
        get { pointer[index] }
        set { pointer[index] = newValue }
    }

    @inline(__always)
    func removeAll() {
        count = 0
    }

    @inline(__always)
    func append(_ element: Element) {
        if count == capacity {
            grow(to: capacity * 2)
        }
        pointer[count] = element
        count += 1
    }

    /// Makes room for `count` elements, all set to `value`.
    func reset(count: Int, value: Element) {
        if count > capacity {
            grow(to: max(count, capacity * 2))
        }
        pointer.update(repeating: value, count: count)
        self.count = count
    }

    private func grow(to newCapacity: Int) {
        let next = UnsafeMutablePointer<Element>.allocate(capacity: newCapacity)
        next.moveUpdate(from: pointer, count: count)
        pointer.deallocate()
        pointer = next
        capacity = newCapacity
    }
}

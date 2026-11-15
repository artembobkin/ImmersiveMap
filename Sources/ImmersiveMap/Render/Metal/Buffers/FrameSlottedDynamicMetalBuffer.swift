// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  FrameSlottedDynamicMetalBuffer.swift
//  ImmersiveMap
//

import Metal

/// Holds an independent reusable DynamicMetalBuffer per in-flight frame slot.
final class FrameSlottedDynamicMetalBuffer<Element> {
    private let stores: [DynamicMetalBuffer<Element>]

    init(metalDevice: MTLDevice,
         slotsCount: Int,
         options: MTLResourceOptions = [],
         minimumCapacity: Int = 1) {
        precondition(slotsCount > 0, "FrameSlottedDynamicMetalBuffer requires at least one slot.")
        self.stores = (0..<slotsCount).map { _ in
            DynamicMetalBuffer(metalDevice: metalDevice,
                               options: options,
                               minimumCapacity: minimumCapacity)
        }
    }

    @discardableResult
    func ensureCapacity(slot: Int, count: Int) -> MTLBuffer {
        store(for: slot).ensureCapacity(count: count)
    }

    func buffer(for slot: Int) -> MTLBuffer {
        store(for: slot).buffer
    }

    func capacity(for slot: Int) -> Int {
        store(for: slot).capacity
    }

    private func store(for slot: Int) -> DynamicMetalBuffer<Element> {
        precondition(slot >= 0 && slot < stores.count, "Frame slot index is out of bounds.")
        return stores[slot]
    }
}

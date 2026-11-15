// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  DynamicMetalBuffer.swift
//  ImmersiveMap
//

import Metal

/// Reusable typed MTLBuffer wrapper that only grows capacity when needed.
///
/// The growth policy is exponential (`x2`) to avoid repeated reallocations in hot paths.
final class DynamicMetalBuffer<Element> {
    private let metalDevice: MTLDevice
    private let options: MTLResourceOptions
    private let minimumCapacity: Int

    private(set) var buffer: MTLBuffer
    private(set) var capacity: Int

    init(metalDevice: MTLDevice,
         options: MTLResourceOptions = [],
         minimumCapacity: Int = 1) {
        let clampedMinimumCapacity = max(1, minimumCapacity)
        self.metalDevice = metalDevice
        self.options = options
        self.minimumCapacity = clampedMinimumCapacity
        self.capacity = clampedMinimumCapacity
        self.buffer = DynamicMetalBuffer.makeBuffer(metalDevice: metalDevice,
                                                    elementCount: clampedMinimumCapacity,
                                                    options: options)
    }

    @discardableResult
    func ensureCapacity(count: Int) -> MTLBuffer {
        let requested = max(minimumCapacity, count)
        guard requested > capacity else {
            return buffer
        }

        let expandedCapacity = expandedCapacity(for: requested)
        buffer = DynamicMetalBuffer.makeBuffer(metalDevice: metalDevice,
                                               elementCount: expandedCapacity,
                                               options: options)
        capacity = expandedCapacity
        return buffer
    }

    private func expandedCapacity(for requested: Int) -> Int {
        var candidate = max(minimumCapacity, capacity)
        while candidate < requested {
            let (next, overflow) = candidate.multipliedReportingOverflow(by: 2)
            if overflow {
                return requested
            }
            candidate = next
        }
        return candidate
    }

    private static func makeBuffer(metalDevice: MTLDevice,
                                   elementCount: Int,
                                   options: MTLResourceOptions) -> MTLBuffer {
        let clampedElementCount = max(1, elementCount)
        let (length, overflow) = clampedElementCount.multipliedReportingOverflow(by: MemoryLayout<Element>.stride)
        precondition(overflow == false, "DynamicMetalBuffer allocation overflow for \(Element.self).")

        guard let buffer = metalDevice.makeBuffer(length: length, options: options) else {
            fatalError("Failed to allocate MTLBuffer for \(Element.self) with length \(length).")
        }
        return buffer
    }
}

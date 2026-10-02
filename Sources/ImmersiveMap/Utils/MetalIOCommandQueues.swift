// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

#if !targetEnvironment(simulator)
/// The IO command queue of a device, which loads a file's bytes straight
/// into a buffer or a texture (Metal's fast resource loading). The
/// simulator SDK has no such surface, so the type is absent there.
enum MetalIOCommandQueues {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queuesByDevice: [ObjectIdentifier: MTLIOCommandQueue] = [:]

    /// One IO command queue per device, shared by everything that loads
    /// from disk: nil on a device without Metal 3, and when the queue
    /// cannot be created.
    ///
    /// The queue is a device-level object, and an app runs one engine, so
    /// a queue per user bought nothing. They cost, though: each queue
    /// spawns four IO threads that sit parked in the driver
    /// (`IOGPUIOCommandQueuePerformIO`, their idle state, not a hang) and
    /// holds kernel-side resources for as long as it lives. A process that
    /// builds engines in a loop (the test suite creates dozens through
    /// `ImmersiveMapStillRecorder` and the video export, and a host app
    /// that recreates its renderer does the same) piles those up, and past
    /// some count loads on freshly created queues stopped completing in
    /// the test suite. Sharing keeps the count at one per device no matter
    /// how many engines come and go.
    static func shared(for metalDevice: MTLDevice) -> MTLIOCommandQueue? {
        guard metalDevice.supportsFamily(.metal3) else {
            return nil
        }
        let key = ObjectIdentifier(metalDevice)
        lock.lock()
        defer { lock.unlock() }
        if let existing = queuesByDevice[key] {
            return existing
        }
        let descriptor = MTLIOCommandQueueDescriptor()
        descriptor.type = .concurrent
        guard let queue = try? metalDevice.makeIOCommandQueue(descriptor: descriptor) else {
            return nil
        }
        queuesByDevice[key] = queue
        return queue
    }
}
#endif

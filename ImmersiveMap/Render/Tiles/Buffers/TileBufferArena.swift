// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

/// A sub-range of a tile's single backing allocation: everything a draw call
/// needs to bind it, so consumers never reach back to the arena.
struct TileBufferView {
    let buffer: MTLBuffer
    let offset: Int
    /// Element count of the typed content (vertices, indices, styles...).
    let count: Int
}

/// Sub-allocates every buffer of one tile from a single Metal allocation.
/// A tile used to make up to ~70 small `makeBuffer(bytes:)` calls, each with
/// its own page-rounded allocation; one arena removes the allocation churn,
/// the page tails, and turns the cache's purgeable transitions and byte
/// accounting into a single-resource operation.
///
/// Usage: measure the exact total with `alignedSize(of:)` over the same
/// arrays the write pass appends (the append preconditions catch any drift),
/// create the arena with that length, then `append` in the same order.
final class TileBufferArena {
    /// Every span starts 256-byte aligned: constant-address-space binds
    /// (the tile style and overview-mask pointers) require 256-byte
    /// setVertexBuffer offsets on Mac-family GPUs, and one alignment rule for
    /// every span keeps the measure and write passes trivially symmetric.
    /// The worst-case tail per span is noise next to the ~70 page-rounded
    /// allocations the arena replaces. (Same rule as the per-route buffer
    /// offsets in RouteRenderSubsystem.)
    static let spanAlignment = 256

    private let buffer: MTLBuffer
    private var cursor = 0

    init?(metalDevice: MTLDevice, length: Int) {
        guard length > 0, let buffer = metalDevice.makeBuffer(length: length) else {
            return nil
        }
        self.buffer = buffer
    }

    var backingBuffer: MTLBuffer {
        buffer
    }

    /// The aligned footprint `append(values)` will consume; the measure pass
    /// sums these over the exact arrays the write pass appends.
    static func alignedSize<T>(of values: [T]) -> Int {
        guard values.isEmpty == false else { return 0 }
        let byteCount = values.count * MemoryLayout<T>.stride
        return (byteCount + spanAlignment - 1) & ~(spanAlignment - 1)
    }

    /// Copies the array into the next aligned span; nil for empty arrays,
    /// mirroring the old "no buffer for an empty layer" contract.
    func append<T>(_ values: [T]) -> TileBufferView? {
        guard values.isEmpty == false else { return nil }
        let byteCount = values.count * MemoryLayout<T>.stride
        precondition(cursor + byteCount <= buffer.length,
                     "Tile buffer arena overflow: the measure pass diverged from the write pass")
        let view = TileBufferView(buffer: buffer, offset: cursor, count: values.count)
        values.withUnsafeBytes { source in
            buffer.contents().advanced(by: cursor).copyMemory(from: source.baseAddress!,
                                                              byteCount: byteCount)
        }
        cursor += Self.alignedSize(of: values)
        return view
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Stateless narrowing of 32-bit index arrays to 16 bits when the referenced
/// vertex range allows it. Halves index bandwidth and index-buffer memory for
/// the vast majority of tile layers; geometry that exceeds the range keeps its
/// 32-bit indices.
enum IndexStorageMath {
    /// Largest vertex count whose indices are narrowed. Staying at 65535
    /// vertices keeps every narrowed index strictly below 0xFFFF, Metal's
    /// primitive-restart sentinel for strip topologies, so the buffers remain
    /// topology-agnostic.
    static let maximumNarrowableVertexCount = Int(UInt16.max)

    /// Returns the indices as `UInt16` when the vertex count is in the
    /// narrowable range, nil otherwise (the caller keeps the `UInt32` array).
    /// An out-of-range index value (possible only in corrupt input) falls back
    /// to the wide path rather than truncating.
    static func narrowedIndices(_ indices: [UInt32], vertexCount: Int) -> [UInt16]? {
        guard vertexCount <= maximumNarrowableVertexCount, indices.isEmpty == false else {
            return nil
        }
        var narrowed = [UInt16]()
        narrowed.reserveCapacity(indices.count)
        for index in indices {
            guard index < UInt32(UInt16.max) else {
                return nil
            }
            narrowed.append(UInt16(index))
        }
        return narrowed
    }
}

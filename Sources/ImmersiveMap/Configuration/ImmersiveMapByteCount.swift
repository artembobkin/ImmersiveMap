// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// A size in bytes, written in the unit that reads best:
///
///     .preparedTileDiskCacheSize(.gigabytes(2))
///     .preparedTileDiskCacheSize(.megabytes(512))
///
/// A gigabyte here is 1024 megabytes and a megabyte 1024 kilobytes, as
/// memory and caches are counted. A negative size is zero.
public struct ImmersiveMapByteCount: Hashable, Comparable, Sendable {
    /// The size in bytes.
    public let bytes: Int

    public static func bytes(_ count: Int) -> ImmersiveMapByteCount {
        ImmersiveMapByteCount(bytes: max(count, 0))
    }

    public static func kilobytes(_ count: Double) -> ImmersiveMapByteCount {
        scaled(count, by: 1 << 10)
    }

    public static func megabytes(_ count: Double) -> ImmersiveMapByteCount {
        scaled(count, by: 1 << 20)
    }

    public static func gigabytes(_ count: Double) -> ImmersiveMapByteCount {
        scaled(count, by: 1 << 30)
    }

    public static func < (lhs: ImmersiveMapByteCount, rhs: ImmersiveMapByteCount) -> Bool {
        lhs.bytes < rhs.bytes
    }

    private static func scaled(_ count: Double, by unit: Int) -> ImmersiveMapByteCount {
        let bytes = (count * Double(unit)).rounded()
        guard bytes.isFinite, bytes > 0 else { return ImmersiveMapByteCount(bytes: 0) }
        return ImmersiveMapByteCount(bytes: bytes < Double(Int.max) ? Int(bytes) : Int.max)
    }
}

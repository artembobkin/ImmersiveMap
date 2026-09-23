// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// One directory entry. `runLength == 0` marks a pointer to a leaf directory
/// (offset and length relative to the leaf directories section). Otherwise
/// the entry is `runLength` consecutive tile ids that all share one tile
/// (offset and length relative to the tile data section).
package struct PMTilesEntry: Sendable, Equatable {
    package var tileID: UInt64
    package var offset: UInt64
    package var length: UInt32
    package var runLength: UInt32

    package init(tileID: UInt64, offset: UInt64, length: UInt32, runLength: UInt32) {
        self.tileID = tileID
        self.offset = offset
        self.length = length
        self.runLength = runLength
    }

    package var isLeafPointer: Bool {
        runLength == 0
    }
}

/// A decoded directory: entries sorted by tile id, as the specification
/// requires. The root directory is read once per archive, a leaf directory
/// on demand.
package struct PMTilesDirectory: Sendable, Equatable {
    package enum Lookup: Sendable, Equatable {
        case tile(PMTilesEntry)
        case leaf(PMTilesEntry)
        case missing
    }

    /// A directory with more entries than this is not a directory but a
    /// corrupt length. The reference implementation writes at most a few
    /// thousand entries per directory.
    package static let maximumEntryCount = 10_000_000

    package var entries: [PMTilesEntry]

    package init(entries: [PMTilesEntry]) {
        self.entries = entries
    }

    /// Decodes an already decompressed directory: the entry count, then the
    /// tile id deltas, the run lengths, the lengths, and the offsets, each as
    /// a column of varints. An offset of zero (past the first entry) means
    /// "right after the previous entry", otherwise the stored value is one
    /// more than the offset.
    package init(decoding data: Data) throws {
        var reader = PMTilesVarintReader(data)
        let count64 = try reader.readUInt64()
        guard count64 <= UInt64(Self.maximumEntryCount) else {
            throw PMTilesFormatError.malformedDirectory("entry count \(count64) is out of range")
        }
        let count = Int(count64)

        var entries: [PMTilesEntry] = []
        entries.reserveCapacity(count)
        var lastID: UInt64 = 0
        for index in 0..<count {
            let delta = try reader.readUInt64()
            let (id, overflow) = lastID.addingReportingOverflow(delta)
            guard overflow == false else {
                throw PMTilesFormatError.malformedDirectory("tile id overflow at entry \(index)")
            }
            lastID = id
            entries.append(PMTilesEntry(tileID: id, offset: 0, length: 0, runLength: 0))
        }
        for index in 0..<count {
            let runLength = try reader.readUInt64()
            guard runLength <= UInt64(UInt32.max) else {
                throw PMTilesFormatError.malformedDirectory("run length out of range at entry \(index)")
            }
            entries[index].runLength = UInt32(runLength)
        }
        for index in 0..<count {
            let length = try reader.readUInt64()
            guard length <= UInt64(UInt32.max) else {
                throw PMTilesFormatError.malformedDirectory("length out of range at entry \(index)")
            }
            entries[index].length = UInt32(length)
        }
        for index in 0..<count {
            let stored = try reader.readUInt64()
            if stored == 0, index > 0 {
                let previous = entries[index - 1]
                entries[index].offset = previous.offset + UInt64(previous.length)
            } else {
                guard stored > 0 else {
                    throw PMTilesFormatError.malformedDirectory("zero offset on the first entry")
                }
                entries[index].offset = stored - 1
            }
        }
        self.entries = entries
    }

    /// Finds the entry that answers `tileID`: an exact match, a run that
    /// covers it, or the leaf directory it would be in. Binary search, so a
    /// root directory of thousands of entries costs a dozen probes.
    package func lookup(tileID: UInt64) -> Lookup {
        var low = 0
        var high = entries.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let entry = entries[middle]
            if entry.tileID > tileID {
                high = middle - 1
            } else if entry.tileID < tileID {
                low = middle + 1
            } else {
                return entry.isLeafPointer ? .leaf(entry) : .tile(entry)
            }
        }
        // `high` is the last entry with a smaller tile id, or -1.
        guard high >= 0 else {
            return .missing
        }
        let entry = entries[high]
        if entry.isLeafPointer {
            return .leaf(entry)
        }
        if tileID - entry.tileID < UInt64(entry.runLength) {
            return .tile(entry)
        }
        return .missing
    }
}

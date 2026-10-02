// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The index buffers the map's buildings draw from while models stand in
/// for some of them.
///
/// A tile's buildings are one index buffer, one building after another, and
/// drawn in one call. A model takes buildings out of the middle of it, and
/// the buffer itself cannot change: the building comes back when its model
/// goes, and the frames in flight still read it. So a tile with hidden
/// buildings gets a working buffer of its own, a copy of its indices
/// without the hidden buildings' ranges (`TileBuildingRange`), and draws
/// that, in one call again. The vertices are shared, only indices are
/// copied, and only for the tiles that hold a hidden building.
///
/// A working buffer is built in the frame the hidden buildings change and
/// kept for as long as its tile lives. With nothing hidden (the models are
/// gone, or not shown yet) the tile draws its own buffer, and the working
/// one waits: the same buildings hidden again cost nothing. The world pass
/// and the shadow casters draw the same tiles and share the buffers.
///
/// Used from the render loop only, like the subsystem that owns it.
final class HiddenBuildingIndexBuffers {
    /// What a tile's buildings draw from this frame.
    enum Indices {
        /// The tile's own buffer, whole: it holds no hidden building.
        case whole
        /// The working buffer, from its start.
        case working(buffer: MTLBuffer, indexCount: Int)
        /// Nothing: every building of the tile is hidden, or the working
        /// buffer could not be allocated.
        case none
    }

    private struct Entry {
        /// The tile the entry was worked out for. Weak, so the cache keeps
        /// no tile alive, and compared by identity, so an entry never
        /// answers for a later tile that took a released one's address.
        weak var tile: MetalTile?
        /// The hidden set the entry was last checked against.
        var generation: UInt64
        /// The runs the working buffer holds, nil for a tile that draws
        /// whole.
        var runs: [Range<Int>]?
        var indices: Indices
    }

    /// The fewest entries worth a sweep for the ones of released tiles.
    private static let minimumSweepEntryCount = 64
    /// The entry count the next sweep runs at: twice what the last one
    /// left, so sweeping stays a small share of the lookups.
    private var sweepEntryCount = HiddenBuildingIndexBuffers.minimumSweepEntryCount

    private var replacedBuildings = ReplacedBuildings.none
    /// The frame hides no building: every tile draws its own buffer.
    private var isHidingNothing = true
    /// The ids left out of the map tiles of each zoom asked for, worked
    /// out once per change (`ReplacedBuildings.ids(forMapTileZoom:)`).
    private var hiddenIDsByZoom: [Int: Set<UInt64>] = [:]
    /// Moves on when the hidden buildings change: an entry of an older
    /// generation is checked again before it answers.
    private var generation: UInt64 = 0
    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Takes the buildings the frame leaves out. Called once before a
    /// pass draws its tiles: the comparison is the only work a frame with
    /// the same buildings hidden does here. With nothing hidden the last
    /// buildings are kept, and the working buffers with them, for the
    /// models' return.
    func update(_ replacedBuildings: ReplacedBuildings) {
        isHidingNothing = replacedBuildings.isEmpty
        guard isHidingNothing == false, replacedBuildings != self.replacedBuildings else {
            return
        }
        self.replacedBuildings = replacedBuildings
        hiddenIDsByZoom.removeAll(keepingCapacity: true)
        generation &+= 1
    }

    /// What `tile` draws its buildings from, the buildings of the last
    /// `update` left out. A tile takes the hidden ids of its own zoom.
    func indices(of tile: MetalTile) -> Indices {
        guard isHidingNothing == false else {
            return .whole
        }
        let key = ObjectIdentifier(tile)
        var entry = entries[key].flatMap { $0.tile === tile ? $0 : nil }
        if let entry, entry.generation == generation {
            return entry.indices
        }

        let extruded = tile.tileBuffers.extruded
        let zoom = tile.tile.z
        let hiddenIDs: Set<UInt64>
        if let known = hiddenIDsByZoom[zoom] {
            hiddenIDs = known
        } else {
            hiddenIDs = replacedBuildings.ids(forMapTileZoom: zoom)
            hiddenIDsByZoom[zoom] = hiddenIDs
        }
        let runs = extruded.indexRuns(hiding: hiddenIDs)
        if let known = entry, known.runs == runs {
            // Another set of hidden buildings that takes the same ones out
            // of this tile: its working buffer stands.
            entry?.generation = generation
            entries[key] = entry
            return known.indices
        }
        let indices = Self.makeIndices(of: extruded, runs: runs, tile: tile.tile)
        entries[key] = Entry(tile: tile, generation: generation, runs: runs, indices: indices)
        sweepIfNeeded()
        return indices
    }

    private static func makeIndices(of extruded: TileBuffers.Extruded,
                                    runs: [Range<Int>]?,
                                    tile: Tile) -> Indices {
        guard let runs else {
            return .whole
        }
        let indexCount = runs.reduce(0) { $0 + $1.count }
        guard indexCount > 0, let source = extruded.indices else {
            return .none
        }
        let indexByteCount = extruded.indexType == .uint16 ? MemoryLayout<UInt16>.stride : MemoryLayout<UInt32>.stride
        // Without the buffer the tile's buildings are not drawn: there is
        // no second way to draw them.
        guard let buffer = source.buffer.device.makeBuffer(length: indexCount * indexByteCount,
                                                           options: .storageModeShared) else {
            return .none
        }
        copy(runs: runs,
             indexByteCount: indexByteCount,
             from: source.buffer.contents() + source.offset,
             to: buffer.contents())
        buffer.label = "Buildings \(tile.z)/\(tile.x)/\(tile.y) without the replaced"
        return .working(buffer: buffer, indexCount: indexCount)
    }

    /// Copies the indices of `runs`, one run after another, from a tile's
    /// index buffer to the start of a working one. `indexByteCount` is the
    /// width of an index, 2 or 4 bytes.
    static func copy(runs: [Range<Int>],
                     indexByteCount: Int,
                     from source: UnsafeRawPointer,
                     to destination: UnsafeMutableRawPointer) {
        var written = 0
        for run in runs {
            let byteCount = run.count * indexByteCount
            (destination + written).copyMemory(from: source + run.lowerBound * indexByteCount, byteCount: byteCount)
            written += byteCount
        }
    }

    /// Drops the entries of released tiles, and their working buffers with
    /// them, once the entries have doubled since the last sweep.
    private func sweepIfNeeded() {
        guard entries.count > sweepEntryCount else { return }
        entries = entries.filter { $0.value.tile != nil }
        sweepEntryCount = max(Self.minimumSweepEntryCount, entries.count * 2)
    }
}

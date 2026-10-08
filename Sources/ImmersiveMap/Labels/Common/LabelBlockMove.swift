// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  LabelBlockMove.swift
//  ImmersiveMap
//

/// A run of a working set that survived a topology change: the labels of
/// one tile, contiguous in tile order in the old span and in the new one.
/// The per-label state of a surviving tile is carried by copying the run,
/// no key is looked at: inside a tile nothing ever moves, the tile's
/// labels and their order are fixed when the tile is parsed.
struct LabelBlockMove: Equatable {
    let oldStart: Int
    let newStart: Int
    let count: Int
}

/// What a topology change did to a working set: the new size, the runs
/// that survived, and the runs that left and arrived with their keys, for
/// the state arrays index-aligned with the set.
///
/// A feature whose copy changes tile (the exact tile replacing the parent
/// at a zoom step, a tile boundary crossing it in a pan) is in no
/// surviving run and would start over invisible. `seeded` adds a one-label
/// move for each label that takes over a lit copy of its key, so the
/// feature keeps its fade whatever order its tiles come and go in.
struct LabelWorkingSetChange {
    let count: Int
    let moves: [LabelBlockMove]
    /// The runs of the old span whose tiles left (or were replaced).
    let departedRuns: [Range<Int>]
    /// The runs of the new span whose tiles arrived (or were replaced).
    let arrivedRuns: [Range<Int>]
    /// Each label's key in the old span and in the new one.
    let previousKeys: [UInt64]
    let keys: [UInt64]

    static let empty = LabelWorkingSetChange(count: 0, moves: [])

    init(count: Int,
         moves: [LabelBlockMove],
         departedRuns: [Range<Int>] = [],
         arrivedRuns: [Range<Int>] = [],
         previousKeys: [UInt64] = [],
         keys: [UInt64] = []) {
        self.count = count
        self.moves = moves
        self.departedRuns = departedRuns
        self.arrivedRuns = arrivedRuns
        self.previousKeys = previousKeys
        self.keys = keys
    }

    /// `old` carried into a new array of `count` entries, `initial`
    /// everywhere a run did not survive. A move outside either array is
    /// clipped: a stale move never reads or writes past an end.
    func carry<T>(_ old: [T], initial: T) -> [T] {
        var next = [T](repeating: initial, count: count)
        guard old.isEmpty == false, moves.isEmpty == false else {
            return next
        }
        old.withUnsafeBufferPointer { oldBuffer in
            next.withUnsafeMutableBufferPointer { nextBuffer in
                for move in moves {
                    let count = min(move.count,
                                    min(oldBuffer.count - move.oldStart, nextBuffer.count - move.newStart))
                    guard count > 0, move.oldStart >= 0, move.newStart >= 0 else {
                        continue
                    }
                    let source = UnsafeBufferPointer(rebasing: oldBuffer[move.oldStart..<(move.oldStart + count)])
                    UnsafeMutableBufferPointer(rebasing: nextBuffer[move.newStart..<(move.newStart + count)])
                        .update(fromContentsOf: source)
                }
            }
        }
        return next
    }

    /// The change with a one-label move for every label that should take
    /// over the fade of another copy of its feature, matched by key:
    ///
    /// - a label of an arriving run, from the fullest lit copy anywhere in
    ///   the old span. A copy that arrives beside a lit one takes over at
    ///   once, and the frame's collision solve
    ///   decides which of the two shows; it never waits unlit beside the
    ///   copy it replaces.
    /// - an unlit label of a surviving run, from the fullest lit copy in a
    ///   departing run: the copy that was showing left, this one is next.
    ///
    /// Two small sorted tables of lit labels (`oldAlphas` above
    /// `threshold`) and a binary search per candidate label, once per
    /// topology change and only when a tile arrived or a lit label left:
    /// no hashing, and nothing on a frame whose tiles did not change.
    func seeded(oldAlphas: [Float], threshold: Float) -> LabelWorkingSetChange {
        guard arrivedRuns.isEmpty == false || departedRuns.isEmpty == false else {
            return self
        }
        struct Entry {
            var key: UInt64
            var oldIndex: Int32
            var alpha: Float
        }
        func ordered(_ lhs: Entry, _ rhs: Entry) -> Bool {
            lhs.key != rhs.key ? lhs.key < rhs.key : lhs.alpha > rhs.alpha
        }
        var departedLit: [Entry] = []
        var allLit: [Entry] = []
        previousKeys.withUnsafeBufferPointer { keys in
            oldAlphas.withUnsafeBufferPointer { alphas in
                let limit = min(keys.count, alphas.count)
                for run in departedRuns {
                    var index = max(0, run.lowerBound)
                    let end = min(run.upperBound, limit)
                    while index < end {
                        if alphas[index] > threshold {
                            departedLit.append(Entry(key: keys[index], oldIndex: Int32(index), alpha: alphas[index]))
                        }
                        index += 1
                    }
                }
                guard arrivedRuns.isEmpty == false else {
                    return
                }
                allLit = departedLit
                for move in moves {
                    var index = max(0, move.oldStart)
                    let end = min(move.oldStart + move.count, limit)
                    while index < end {
                        if alphas[index] > threshold {
                            allLit.append(Entry(key: keys[index], oldIndex: Int32(index), alpha: alphas[index]))
                        }
                        index += 1
                    }
                }
            }
        }
        guard departedLit.isEmpty == false || allLit.isEmpty == false else {
            return self
        }
        departedLit.sort(by: ordered)
        allLit.sort(by: ordered)

        /// The first entry of `key` in a sorted table: its fullest copy.
        func find(_ key: UInt64, in table: UnsafeBufferPointer<Entry>) -> Int32 {
            var low = 0
            var high = table.count
            while low < high {
                let middle = (low + high) >> 1
                if table[middle].key < key {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low < table.count && table[low].key == key ? table[low].oldIndex : -1
        }

        var seeds: [LabelBlockMove] = []
        keys.withUnsafeBufferPointer { keys in
            if allLit.isEmpty == false {
                allLit.withUnsafeBufferPointer { table in
                    for run in arrivedRuns {
                        var index = max(0, run.lowerBound)
                        let end = min(run.upperBound, keys.count)
                        while index < end {
                            let source = find(keys[index], in: table)
                            if source >= 0 {
                                seeds.append(LabelBlockMove(oldStart: Int(source), newStart: index, count: 1))
                            }
                            index += 1
                        }
                    }
                }
            }
            if departedLit.isEmpty == false {
                departedLit.withUnsafeBufferPointer { table in
                    oldAlphas.withUnsafeBufferPointer { alphas in
                        for move in moves {
                            let count = min(move.count, min(alphas.count - move.oldStart, keys.count - move.newStart))
                            var offset = 0
                            while offset < count {
                                if alphas[move.oldStart + offset] <= threshold {
                                    let source = find(keys[move.newStart + offset], in: table)
                                    if source >= 0 {
                                        seeds.append(LabelBlockMove(oldStart: Int(source),
                                                                    newStart: move.newStart + offset,
                                                                    count: 1))
                                    }
                                }
                                offset += 1
                            }
                        }
                    }
                }
            }
        }
        guard seeds.isEmpty == false else {
            return self
        }
        // After the block moves: a seed overwrites what its run carried.
        return LabelWorkingSetChange(count: count,
                                     moves: moves + seeds,
                                     departedRuns: departedRuns,
                                     arrivedRuns: arrivedRuns,
                                     previousKeys: previousKeys,
                                     keys: keys)
    }
}

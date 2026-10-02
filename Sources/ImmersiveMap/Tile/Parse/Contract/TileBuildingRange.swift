// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Where one building's volume sits in a tile's extruded index buffer: the
/// indices from `indexStart`, `indexCount` of them, belong to the building
/// whose tile feature id is `featureID`.
///
/// A tile keeps these beside its extruded geometry so the frame can leave a
/// building out without parsing the tile again: when a model stands in for
/// a building, the drawer draws from a copy of the indices without the
/// ranges of that building's id (`HiddenBuildingIndexBuffers`). A volume
/// has one range, under its own feature id, and a volume without an id has
/// none. A building mapped as an outline plus parts is so many ids, and a
/// model names each of them: the tile does not work out which part belongs
/// to which outline. The ranges are sorted by `featureID`, then by
/// `indexStart`.
///
/// Sixteen bytes of plain data, stored as they are in the prepared tile.
struct TileBuildingRange: Equatable, Sendable {
    var featureID: UInt64
    var indexStart: UInt32
    var indexCount: UInt32

    /// The runs of a tile's `indexCount` extruded indices to draw when the
    /// buildings in `hiddenFeatureIDs` are left out, in ascending order.
    /// Nil when `ranges` holds none of them, and the tile draws whole.
    /// `ranges` are sorted by feature id, as a tile keeps them.
    static func indexRuns(of ranges: [TileBuildingRange],
                          indexCount: Int,
                          hiding hiddenFeatureIDs: Set<UInt64>) -> [Range<Int>]? {
        guard hiddenFeatureIDs.isEmpty == false, ranges.isEmpty == false else {
            return nil
        }
        var hidden: [Range<Int>] = []
        for featureID in hiddenFeatureIDs {
            // The first range of the id, by bisection.
            var low = 0
            var high = ranges.count
            while low < high {
                let middle = (low + high) / 2
                if ranges[middle].featureID < featureID {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            while low < ranges.count, ranges[low].featureID == featureID {
                let start = Int(ranges[low].indexStart)
                hidden.append(start..<(start + Int(ranges[low].indexCount)))
                low += 1
            }
        }
        guard hidden.isEmpty == false else {
            return nil
        }
        hidden.sort { $0.lowerBound < $1.lowerBound }
        var runs: [Range<Int>] = []
        var cursor = 0
        for range in hidden {
            if range.lowerBound > cursor {
                runs.append(cursor..<range.lowerBound)
            }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < indexCount {
            runs.append(cursor..<indexCount)
        }
        return runs
    }
}

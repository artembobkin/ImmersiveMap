// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Which copy of each label painted on the map draws this frame.
///
/// A surface label reaches past the edge of the tile that carries it, and
/// the same name rides every tile zoom from the one it first ships at. So
/// the ground's rule (every source draws, the finest owns each pixel) would
/// cut the text at tile edges and stack copies of it. Instead one copy of a
/// key draws, from the finest source that carries it, whole and over every
/// tile it crosses. The flat map's wrap copies of the world are separate
/// worlds, each drawing its own copy.
enum SurfaceLabelSelection {
    struct Source {
        let labels: [SurfaceLabelRecord]
        let tileZoom: Int
        let worldWrap: Int8
    }

    struct Item: Equatable {
        let sourceIndex: Int
        let labelIndex: Int
        let key: UInt64
    }

    /// The copies to draw, finest source first: a key already taken by a
    /// finer source of the same world is skipped, as is a label outside
    /// its zooms at `cameraZoom`.
    static func select(sources: [Source], cameraZoom: Double) -> [Item] {
        struct WorldKey: Hashable {
            let key: UInt64
            let worldWrap: Int8
        }
        let order = sources.indices.sorted { lhs, rhs in
            if sources[lhs].tileZoom != sources[rhs].tileZoom {
                return sources[lhs].tileZoom > sources[rhs].tileZoom
            }
            return lhs < rhs
        }
        var taken = Set<WorldKey>()
        var items: [Item] = []
        for sourceIndex in order {
            let source = sources[sourceIndex]
            for (labelIndex, label) in source.labels.enumerated() {
                guard label.placement.isVisible(atZoom: cameraZoom),
                      taken.insert(WorldKey(key: label.key, worldWrap: source.worldWrap)).inserted else {
                    continue
                }
                items.append(Item(sourceIndex: sourceIndex, labelIndex: labelIndex, key: label.key))
            }
        }
        return items
    }
}

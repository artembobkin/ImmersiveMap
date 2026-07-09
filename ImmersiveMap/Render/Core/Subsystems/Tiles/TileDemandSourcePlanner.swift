// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

enum TileDemandSourcePlanner {
    static func makeDemandedSourceTiles(targets: [VisibleTile],
                                        parentFallbackDepth: Int) -> [Tile] {
        var uniqueTiles: [Tile] = []
        uniqueTiles.reserveCapacity(targets.count)
        var seenTiles: Set<Tile> = []

        for target in targets {
            let source = target.tile
            appendUniqueTile(source, to: &uniqueTiles, seenTiles: &seenTiles)

            guard parentFallbackDepth > 0, source.z > 0 else {
                continue
            }

            let lowestParentZoom = max(0, source.z - parentFallbackDepth)
            guard source.z > lowestParentZoom else {
                continue
            }

            for parentZoom in stride(from: source.z - 1, through: lowestParentZoom, by: -1) {
                guard let parent = source.findParentTile(atZoom: parentZoom) else {
                    continue
                }
                appendUniqueTile(parent, to: &uniqueTiles, seenTiles: &seenTiles)
            }
        }

        return uniqueTiles
    }

    private static func appendUniqueTile(_ tile: Tile,
                                         to uniqueTiles: inout [Tile],
                                         seenTiles: inout Set<Tile>) {
        if seenTiles.insert(tile).inserted {
            uniqueTiles.append(tile)
        }
    }
}

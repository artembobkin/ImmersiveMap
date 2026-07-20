// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

enum TileAtlasPageMappingSorter {
    typealias PageMapping = (pageIndex: Int, mapping: TileAtlasTexture.TileData)

    static func sortedPageMappings(tilesTexture: TileAtlasTexture) -> [PageMapping] {
        var pageMappings: [PageMapping] = []
        for (pageIndex, page) in tilesTexture.pages.enumerated() {
            for mapping in page.tileData {
                pageMappings.append((pageIndex: pageIndex, mapping: mapping))
            }
        }
        sort(&pageMappings)
        return pageMappings
    }

    static func sort(_ pageMappings: inout [PageMapping]) {
        pageMappings.sort(by: shouldDrawBefore)
    }

    private static func shouldDrawBefore(_ lhs: PageMapping, _ rhs: PageMapping) -> Bool {
        let lhsMapping = lhs.mapping
        let rhsMapping = rhs.mapping

        if lhsMapping.tile.z != rhsMapping.tile.z {
            return lhsMapping.tile.z < rhsMapping.tile.z
        }

        let lhsIsReplacement = isReplacement(lhsMapping)
        let rhsIsReplacement = isReplacement(rhsMapping)
        if lhsIsReplacement != rhsIsReplacement {
            return lhsIsReplacement
        }

        if lhsMapping.sourceTile.z != rhsMapping.sourceTile.z {
            return lhsMapping.sourceTile.z < rhsMapping.sourceTile.z
        }
        if lhsMapping.tile.x != rhsMapping.tile.x {
            return lhsMapping.tile.x < rhsMapping.tile.x
        }
        if lhsMapping.tile.y != rhsMapping.tile.y {
            return lhsMapping.tile.y < rhsMapping.tile.y
        }
        if lhs.pageIndex != rhs.pageIndex {
            return lhs.pageIndex < rhs.pageIndex
        }
        return Int(lhsMapping.position) < Int(rhsMapping.position)
    }

    private static func isReplacement(_ mapping: TileAtlasTexture.TileData) -> Bool {
        mapping.sourceTile != mapping.tile
    }
}

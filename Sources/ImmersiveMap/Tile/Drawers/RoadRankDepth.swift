// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Where the roads sit in the flat rank-depth band. A road's depth is its
/// rank, and the depth test over the ranks is what orders the roads, not
/// the order they are drawn in: an opaque road writes its rank with
/// blending off, so a pixel several roads cover is shaded once, by the
/// highest of them (the road ribbons in Tile.metal).
///
/// A rank is a band and a style inside it. The bands follow the order the
/// roads paint in, bottom to top: the structures (tunnel, the pedestrian
/// ground, the automobile ground, bridge), in each the roles from the
/// shadow to the paint, then the bridge overlay and the overlay role of
/// every structure. So a casing lies under every fill of its structure, an
/// automobile road over every path, a bridge over the ground. Inside a
/// band the style index is the rank, which the parser hands out by class
/// priority (`TileUnificationStage`).
///
/// The whole ladder stays within the depth the road buckets took before
/// they were ranked, so it is still farther than every real fragment and
/// the buildings' depth test is untouched.
enum RoadRankDepth {
    /// The style ranks of one band. A style past the last one shares it.
    /// Mirrored by kTileRoadBandRanks in Tile.metal.
    static let ranksPerBand = 12

    /// The roles that stack inside a structure, bottom to top. The overlay
    /// role is not one of them: it draws over every structure.
    private static let structureRoles: [RoadPassRole] = [.shadow, .casing, .fill, .detail]

    /// The band of a role of a structure.
    static func band(structureKind: RoadStructureKind, role: RoadPassRole) -> Int {
        let structure = RoadStructureKind.drawOrder.firstIndex(of: structureKind) ?? 0
        if let roleIndex = structureRoles.firstIndex(of: role) {
            return structure * structureRoles.count + roleIndex
        }
        return bridgeOverlayBand + 1 + structure
    }

    /// The bridge overlay: over every role of every structure but the
    /// overlay role.
    static let bridgeOverlayBand = RoadStructureKind.drawOrder.count * structureRoles.count

    static let bandCount = bridgeOverlayBand + 1 + RoadStructureKind.drawOrder.count

    /// The per-draw depth offset of a band (Tile.metal, buffer 7): the road
    /// buckets' own offset, and the bands under this one.
    static func depthOffset(band: Int) -> Float {
        GlobeSurfaceDepthRank.flatRoadsDepthOffset
            + Float(band * ranksPerBand) * GlobeSurfaceDepthRank.layerDepthStep
    }

    /// Every road layer of a tile with its band, nearest first: the order
    /// the roads that blend are drawn in, so a pixel belongs to the highest
    /// of them.
    static let layersNearestFirst: [(structureKind: RoadStructureKind, role: RoadPassRole, band: Int)] = {
        var layers: [(structureKind: RoadStructureKind, role: RoadPassRole, band: Int)] = []
        for structureKind in RoadStructureKind.drawOrder {
            for role in RoadPassRole.drawOrder {
                layers.append((structureKind, role, band(structureKind: structureKind, role: role)))
            }
        }
        return layers.sorted { $0.band > $1.band }
    }()
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// Reads what a polygon feature contributes to the buildings of a tile:
/// whether it is extruded at all, how tall, with which roof, and the
/// candidate that records it until the whole tile has been read and
/// `BuildingExtrusionResolver` can tell the outlines from the parts. What
/// the feature is as a building is the style's reading of the tile
/// (`FeatureStyle.building`); this reader never looks at a tag. The
/// footprint's ground fill is not this reader's either: the ground reader
/// draws it whether or not the building rises.
///
/// Stateless across tiles, so one value serves every parse of a map.
struct BuildingFeatureReader {
    /// What a building layer says about its parts before any feature is
    /// read: the ids of the buildings that have parts, and the footprints
    /// of the parts, so an outline that repeats a part is not extruded twice.
    struct PartInfo {
        let partIds: Set<UInt64>
        let footprintSignatures: Set<BuildingFootprintSignature>

        static let none = PartInfo(partIds: [], footprintSignatures: [])
    }

    /// A feature's extrusion, decided once for all of its polygons.
    struct Extrusion {
        let buildingId: UInt64
        let heights: BuildingExtrusionHeights
    }

    private let extrusionEnabled: Bool
    private let roofShapesEnabled: Bool
    private let minimumSourceZoom: Int
    private let tileExtent = TileCoordinateSpace.tileExtentDouble

    init(options: TileParseOptions) {
        self.extrusionEnabled = options.buildingExtrusionEnabled
        self.roofShapesEnabled = options.buildingRoofShapesEnabled
        self.minimumSourceZoom = options.buildingMinimumSourceZoom
    }

    /// One pass over a layer collecting both the part identifiers and the
    /// part footprint signatures of its buildings, so an outline that repeats
    /// a part is not extruded twice. A layer with no buildings has no parts.
    func partInfo(geometry: TileLayerGeometry, featureStyles: [FeatureStyle]) -> PartInfo {
        guard featureStyles.contains(where: { $0.building != nil }) else { return .none }
        var partIds = Set<UInt64>()
        var signatures = Set<BuildingFootprintSignature>()
        for (featureIndex, feature) in geometry.layer.features.enumerated() {
            guard let building = featureStyles[featureIndex].building, building.isPart else { continue }
            partIds.insert(building.buildingIdentity ?? feature.id)
            let polygons = geometry.polygons(of: feature)
            for polygon in polygons {
                if let signature = BuildingFootprintSignature(polygon: polygon) {
                    signatures.insert(signature)
                }
            }
        }
        return PartInfo(partIds: partIds, footprintSignatures: signatures)
    }

    /// Whether and how the feature is extruded, nil when it stays a flat
    /// ground fill: the style did not read it as a building, the style's
    /// reading says it is hidden, extrusion is off in the settings, the tile
    /// is coarser than the building grid, or the footprint repeats a part
    /// of its own building. The extrusion flag is prepared-cache identity,
    /// so toggling it re-parses instead of serving the other shape from
    /// disk.
    func extrusion(feature: MvtDecodedFeature,
                   style: FeatureStyle,
                   polygons: MultiPolygon,
                   partInfo: PartInfo,
                   tile: Tile) -> Extrusion? {
        guard extrusionEnabled,
              tile.z >= minimumSourceZoom,
              let building = style.building,
              building.isHidden == false else {
            return nil
        }
        let buildingId = building.buildingIdentity ?? feature.id
        let hasParts = partInfo.partIds.contains(buildingId)
        // The footprint signature's canonical rotation is O(n^2) in ring
        // vertices; only building-part dedup needs it. Skip it entirely when
        // there are no part signatures to match (always the case for
        // non-building layers), so large landcover/water polygons don't pay
        // the quadratic cost. Result is unchanged: an empty set never matches.
        let matchesPartFootprint = building.isPart == false
            && partInfo.footprintSignatures.isEmpty == false
            && polygons.contains { polygon in
                guard let signature = BuildingFootprintSignature(polygon: polygon) else {
                    return false
                }
                return partInfo.footprintSignatures.contains(signature)
            }
        guard matchesPartFootprint == false,
              (hasParts && building.isPart == false) == false,
              let heights = extrusionHeights(building: building, tileZoom: tile.z, style: style) else {
            return nil
        }
        return Extrusion(buildingId: buildingId, heights: heights)
    }

    /// The candidate for one polygon of an extruded feature, nil for a
    /// polygon with no height or no usable footprint. The extrusion path's
    /// ONE entry into render space: the candidate's rings all flip here, so
    /// the unclipped ring shares exact coordinates with the clipped one on
    /// uncut edges.
    func candidate(polygon: Polygon,
                   parsedGeometry: ParsePolygon.ParsedGeometry,
                   styleKey: UInt8,
                   extrusion: Extrusion) -> BuildingExtrusionCandidate? {
        let heights = extrusion.heights
        guard heights.top > heights.base,
              let footprintSignature = BuildingFootprintSignature(polygon: polygon) else {
            return nil
        }
        let unclippedExterior = TileCoordinateSpace.renderPoints(
            polygon.exteriorRing.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        )
        return BuildingExtrusionCandidate(styleKey: styleKey,
                                          buildingId: extrusion.buildingId,
                                          footprintSignature: footprintSignature,
                                          clippedExterior: TileCoordinateSpace.renderPoints(parsedGeometry.clipped.exterior),
                                          clippedInteriors: parsedGeometry.clipped.interiors.map(TileCoordinateSpace.renderPoints),
                                          unclippedExterior: unclippedExterior,
                                          hasUnclippedInteriorRings: polygon.interiorRings.contains { $0.count >= 3 },
                                          roof: parsedGeometry.parsedPolygon,
                                          roofInfo: heights.roof,
                                          baseHeight: heights.base,
                                          topHeight: heights.top)
    }

    /// After the whole tile is read: resolves the candidates against each
    /// other and builds a mesh for each survivor.
    func appendExtrudedMeshes(resolving candidates: [BuildingExtrusionCandidate],
                              into result: inout ReadingStageResult) {
        for candidate in BuildingExtrusionResolver.resolveExterior(candidates) {
            if let extrudedMesh = BuildingExtrusionMeshBuilder.build(clippedExterior: candidate.clippedExterior,
                                                                     clippedInteriors: candidate.clippedInteriors,
                                                                     unclippedExterior: candidate.unclippedExterior,
                                                                     hasUnclippedInteriorRings: candidate.hasUnclippedInteriorRings,
                                                                     roof: candidate.roof,
                                                                     roofInfo: candidate.roofInfo,
                                                                     baseHeight: candidate.baseHeight,
                                                                     topHeight: candidate.topHeight,
                                                                     tileExtent: Float(tileExtent)) {
                result.extrudedByStyle[candidate.styleKey, default: []].append(extrudedMesh)
            }
        }
    }

    /// The building's heights in tile units at the tile's zoom, from the
    /// style's reading or the style's fallback height; nil when nothing says
    /// how tall it is.
    func extrusionHeights(building: ImmersiveMapBuildingExtrusion,
                          tileZoom: Int,
                          style: FeatureStyle) -> BuildingExtrusionHeights? {
        let fallbackHeight = style.extrusionFallbackHeight
        if building.heightMetres == nil && building.baseHeightMetres == nil {
            guard fallbackHeight > 0 else { return nil }
        }

        let resolvedHeight = building.heightMetres ?? fallbackHeight
        guard resolvedHeight > 0 else { return nil }
        let resolvedMinHeight = building.baseHeightMetres ?? 0

        let zoomDelta = tileZoom - style.extrusionAnchorZoom
        let zoomScale = powf(2.0, Float(zoomDelta))
        let scaledHeight = resolvedHeight * style.extrusionHeightScale * zoomScale
        let scaledMinHeight = resolvedMinHeight * style.extrusionHeightScale * zoomScale

        let base = max(0, min(scaledMinHeight, scaledHeight))
        let top = max(scaledHeight, base)
        // Shaped roofs off: every building takes the flat lid at its full
        // height. Part of the prepared-cache identity
        // (PreparedTileCacheIdentity), so toggling re-parses instead of
        // serving the other shape from disk.
        guard roofShapesEnabled, let roof = building.roof else {
            return BuildingExtrusionHeights(base: base, top: top, roof: nil)
        }
        return BuildingExtrusionHeights(base: base,
                                        top: top,
                                        roof: RoofInfo(height: roof.heightMetres * style.extrusionHeightScale * zoomScale,
                                                       shape: roof.shape,
                                                       orientation: roof.orientation,
                                                       directionDegrees: roof.directionDegrees))
    }
}

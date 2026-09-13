// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// Reads what a polygon feature contributes to the buildings of a tile:
/// whether it is extruded at all, how tall, with which roof, and the
/// candidate that records it until the whole tile has been read and
/// `BuildingExtrusionResolver` can tell the outlines from the parts. The
/// footprint's ground fill is not this reader's: the ground reader draws it
/// whether or not the building rises.
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
    private let roofParser = RoofAttributesParser()
    private let tileExtent = TileCoordinateSpace.tileExtentDouble

    init(options: TileParseOptions) {
        self.extrusionEnabled = options.buildingExtrusionEnabled
        self.roofShapesEnabled = options.buildingRoofShapesEnabled
        self.minimumSourceZoom = options.buildingMinimumSourceZoom
    }

    /// One pass over a building layer collecting both the part identifiers
    /// and the part footprint signatures, from attributes the caller already
    /// decoded. Any other layer has no parts.
    func partInfo(layerName: String,
                  geometry: TileLayerGeometry,
                  attributes featureAttributes: [[String: MvtValue]]) -> PartInfo {
        guard layerName == "building" else { return .none }
        var partIds = Set<UInt64>()
        var signatures = Set<BuildingFootprintSignature>()
        for (featureIndex, feature) in geometry.layer.features.enumerated() {
            let attributes = featureAttributes[featureIndex]
            guard MvtValue.isTruthy(attributes["building:part"]) else { continue }
            partIds.insert(Self.buildingIdentifier(attributes: attributes, featureId: feature.id))
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
    /// ground fill.
    ///
    /// `extrude` is the Mapbox convention (present, "true"); the
    /// OpenMapTiles building layer has no such field (it drives height
    /// from render_height and hides 3D via hide_3d). Extrude when the
    /// flag is true OR absent, and suppress only when explicitly false
    /// or hide_3d is set - preserving Mapbox behaviour, enabling OMT.
    /// With extrusion switched off in the settings nothing is
    /// extruded at all and the footprint stays a flat ground
    /// fill; the flag is prepared-cache identity, so toggling
    /// re-parses instead of serving the other shape from disk.
    /// Tiles coarser than the building grid never draw
    /// buildings, so their merged blocks are not tessellated
    /// or uploaded either.
    func extrusion(feature: MvtDecodedFeature,
                   attributes: [String: MvtValue],
                   style: FeatureStyle,
                   polygons: MultiPolygon,
                   partInfo: PartInfo,
                   tile: Tile) -> Extrusion? {
        guard extrusionEnabled,
              tile.z >= minimumSourceZoom,
              style.usesExtrusion else {
            return nil
        }
        let extrudeFlag = attributes["extrude"]?.boolValue
        let isBuildingPart = MvtValue.isTruthy(attributes["building:part"])
        let buildingId = Self.buildingIdentifier(attributes: attributes, featureId: feature.id)
        let hasParts = partInfo.partIds.contains(buildingId)
        // The footprint signature's canonical rotation is O(n^2) in ring
        // vertices; only building-part dedup needs it. Skip it entirely when
        // there are no part signatures to match (always the case for
        // non-building layers), so large landcover/water polygons don't pay
        // the quadratic cost. Result is unchanged: an empty set never matches.
        let matchesPartFootprint = isBuildingPart == false
            && partInfo.footprintSignatures.isEmpty == false
            && polygons.contains { polygon in
                guard let signature = BuildingFootprintSignature(polygon: polygon) else {
                    return false
                }
                return partInfo.footprintSignatures.contains(signature)
            }
        let locationValue = attributes["location"]?.stringValue?.lowercased() ?? ""
        let isUnderground = MvtValue.isTruthy(attributes["underground"])
            || locationValue.contains("underground")
            || locationValue.contains("subterranean")
            || locationValue.contains("tunnel")
            || locationValue.contains("underwater")
        let shouldExtrude = (extrudeFlag != false)
            && !MvtValue.isTruthy(attributes["hide_3d"])
            && !isUnderground
            && !matchesPartFootprint
            && !(hasParts && !isBuildingPart)
        guard shouldExtrude,
              let heights = extrusionHeights(attributes: attributes, tileZoom: tile.z, style: style) else {
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

    /// The building's heights in tile units at the tile's zoom, from either
    /// schema's fields, or the style's fallback height; nil when nothing
    /// says how tall it is.
    func extrusionHeights(attributes: [String: MvtValue], tileZoom: Int, style: FeatureStyle) -> BuildingExtrusionHeights? {
        // `height`/`min_height` are the Mapbox convention; `render_height`/
        // `render_min_height` are the OpenMapTiles convention. Accept either.
        let rawHeight = attributes["height"]?.metresValue
            ?? attributes["render_height"]?.metresValue
        let rawMinHeight = attributes["min_height"]?.metresValue
            ?? attributes["render_min_height"]?.metresValue
        let levelHeight: Float = 3.2
        let rawLevels = attributes["building:levels"]?.metresValue
            ?? attributes["levels"]?.metresValue
        let rawMinLevels = attributes["building:min_level"]?.metresValue
            ?? attributes["min_level"]?.metresValue
        let levelHeightValue = rawLevels.map { $0 * levelHeight }
        let minLevelHeightValue = rawMinLevels.map { $0 * levelHeight }
        let fallbackHeight = style.extrusionFallbackHeight

        if rawHeight == nil && rawMinHeight == nil && levelHeightValue == nil {
            guard fallbackHeight > 0 else { return nil }
        }

        let resolvedHeight = rawHeight ?? levelHeightValue ?? fallbackHeight
        guard resolvedHeight > 0 else { return nil }
        let resolvedMinHeight = rawMinHeight ?? minLevelHeightValue ?? 0

        let zoomDelta = tileZoom - style.extrusionAnchorZoom
        let zoomScale = powf(2.0, Float(zoomDelta))
        let scaledHeight = resolvedHeight * style.extrusionHeightScale * zoomScale
        let scaledMinHeight = resolvedMinHeight * style.extrusionHeightScale * zoomScale

        let base = max(0, min(scaledMinHeight, scaledHeight))
        let top = max(scaledHeight, base)
        // Shaped roofs off: every building takes the flat lid at its full
        // height, and the roof attributes are never parsed. Part of the
        // prepared-cache identity (PreparedTileCacheIdentity), so toggling
        // re-parses instead of serving the other shape from disk.
        guard roofShapesEnabled else {
            return BuildingExtrusionHeights(base: base, top: top, roof: nil)
        }
        let roofInfo = roofParser.parse(attributes: attributes, numericParser: { $0.metresValue })
        let scaledRoof = roofInfo.map {
            RoofInfo(height: $0.height * style.extrusionHeightScale * zoomScale,
                     shape: $0.shape,
                     orientation: $0.orientation,
                     directionDegrees: $0.directionDegrees)
        }
        return BuildingExtrusionHeights(base: base, top: top, roof: scaledRoof)
    }

    /// The building a feature belongs to: the id the tile names, or the
    /// feature's own.
    static func buildingIdentifier(attributes: [String: MvtValue], featureId: UInt64) -> UInt64 {
        if let id = attributes["osm_id"]?.uint64Value {
            return id
        }
        if let id = attributes["id"]?.uint64Value {
            return id
        }
        if let id = attributes["building_id"]?.uint64Value {
            return id
        }
        return featureId
    }
}

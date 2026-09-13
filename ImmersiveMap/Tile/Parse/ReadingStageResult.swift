// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What the reading stage accumulates as it walks a tile's layers, and what
/// the unification stage packs into the tile's streams. The feature readers
/// append through the methods here and nowhere else, so the invariants
/// between the buckets (a style is registered under the key its polygons
/// use, a road polygon carries the sequence number of its arrival) hold in
/// one place.
///
/// The ground and bridge buckets are keyed by style: their draw order is the
/// style order. The road bucket is ordered explicitly, since roads sort by
/// structure, layer, pass and class before the style.
struct ReadingStageResult {
    /// Ground fills and line ribbons, drawn under everything else.
    var polygonByStyle: [UInt8: [ParsedPolygon]] = [:]
    var styles: [UInt8: FeatureStyle] = [:]
    /// The separate-road path's polygons: by style for the flat layer, and
    /// in arrival order with their sort keys for the phase buckets.
    var roadPolygonByStyle: [UInt8: [ParsedPolygon]] = [:]
    var orderedRoadPolygons: [OrderedRoadPolygon] = []
    var roadStyles: [UInt8: FeatureStyle] = [:]
    /// Bridge decks and the lines on them, drawn over the roads.
    var bridgePolygonByStyle: [UInt8: [ParsedPolygon]] = [:]
    var bridgeStyles: [UInt8: FeatureStyle] = [:]
    var extrudedByStyle: [UInt8: [ParsedExtrudedMesh]] = [:]
    var textLabels: [ParsedTextLabel] = []
    /// The texts of the tile's own water-name labels, so the names the
    /// parser synthesizes at the coarse zooms skip what the tile already
    /// shows.
    var waterNameTexts: Set<String> = []
    var roadTextLabels: [ParsedRoadTextLabel] = []
    var layerTimings: [TileParseLayerTiming] = []
    private var roadPolygonSequence = 0

    /// Records the style a ground or bridge key draws with, the first time
    /// the key is seen: every later feature of the key shares it.
    mutating func registerStyle(_ style: FeatureStyle, key: UInt8, placement: LinePlacement) {
        switch placement {
        case .ground:
            if styles[key] == nil {
                styles[key] = style
            }
        case .bridgeOverlay:
            if bridgeStyles[key] == nil {
                bridgeStyles[key] = style
            }
        }
    }

    /// The same for a key on the separate-road path.
    mutating func registerRoadStyle(_ style: FeatureStyle, key: UInt8) {
        if roadStyles[key] == nil {
            roadStyles[key] = style
        }
    }

    /// A polygon of the ground or the bridge overlay, by its placement.
    mutating func appendGround(_ polygon: ParsedPolygon, key: UInt8, placement: LinePlacement) {
        switch placement {
        case .ground:
            polygonByStyle[key, default: []].append(polygon)
        case .bridgeOverlay:
            bridgePolygonByStyle[key, default: []].append(polygon)
        }
    }

    /// A polygon of the separate-road path, with the keys it sorts by
    /// (`OrderedRoadPolygon.sort`). The sequence number is its arrival
    /// order, the last tie-breaker.
    mutating func appendRoad(_ polygon: ParsedPolygon,
                             key: UInt8,
                             structureKind: RoadStructureKind,
                             layer: Int,
                             classPriority: Int,
                             passRole: RoadPassRole) {
        roadPolygonByStyle[key, default: []].append(polygon)
        orderedRoadPolygons.append(OrderedRoadPolygon(polygon: polygon,
                                                      styleKey: key,
                                                      structureKind: structureKind,
                                                      layer: layer,
                                                      classPriority: classPriority,
                                                      passRole: passRole,
                                                      sequence: roadPolygonSequence))
        roadPolygonSequence += 1
    }

    /// Drops the style buckets nothing was appended to, so unification sees
    /// only keys that draw.
    mutating func removeEmptyBuckets() {
        polygonByStyle = polygonByStyle.filter { $0.value.isEmpty == false }
        roadPolygonByStyle = roadPolygonByStyle.filter { $0.value.isEmpty == false }
        bridgePolygonByStyle = bridgePolygonByStyle.filter { $0.value.isEmpty == false }
        extrudedByStyle = extrudedByStyle.filter { $0.value.isEmpty == false }
    }
}

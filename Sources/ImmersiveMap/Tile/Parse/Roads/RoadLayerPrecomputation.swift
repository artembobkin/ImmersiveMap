// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt
import simd

/// A road line decoded, converted, and exact-clipped once: the pre-pass
/// counts shared endpoints from it and the line reader tessellates from it,
/// so the geometry work is not repeated per pass.
struct PreparedRoadLine {
    let points: [SIMD2<Float>]
    let exactFragments: [ClippedLineFragment]
}

/// What the separate-road path knows about a whole road layer before any
/// of its features is read: every line stitched into streets and the
/// connections counted. Built once per road layer at street zooms, and
/// `empty` for every other layer.
struct RoadLayerPrecomputation {
    let sharedPointCounts: [RoadConnectionPointKey: Int]
    /// The nodes where a road continues as another piece of the same
    /// style: for each point, the road identity keys (`RoadStyle.key`) of
    /// which two or more features END there. The pieces the tiles ship
    /// cut at such a node draw as separate ribbons whenever the stitcher
    /// leaves them apart (no name on the geometry, a third road meeting
    /// at the node, a footway of the pedestrian tier), and each ends in a
    /// hard butt cut square to its own last segment. Where the two
    /// directions differ, the cuts leave a wedge of ground open on the
    /// outside of the bend, a hairline at a fraction of a degree. The
    /// line reader rounds a connected end at one of these nodes off with a
    /// cap: the overlap of two ribbons of one style is invisible under the
    /// road sheet, which blends each pixel once, and the wedge is filled
    /// at any angle. A node shared with a road of another style is a
    /// junction, and its ends stay square.
    let continuationKeysByPoint: [RoadConnectionPointKey: Set<UInt8>]
    let linesByFeatureIndex: [[PreparedRoadLine]]

    static let empty = RoadLayerPrecomputation(sharedPointCounts: [:],
                                               continuationKeysByPoint: [:],
                                               linesByFeatureIndex: [])

    static func build(geometry: TileLayerGeometry,
                      featureFacts: [ImmersiveMapFeatureFacts],
                      featureStyles: [FeatureStyle],
                      lineClipper: LineClipper,
                      tile: Tile) -> RoadLayerPrecomputation {
        let layer = geometry.layer
        let tileExtent = Float(TileCoordinateSpace.tileExtentDouble)
        var rawLinesByFeatureIndex = Array(repeating: [[SIMD2<Float>]](), count: layer.features.count)
        // Every feature as a road, nil for one that draws as none (hidden,
        // a fill, a label): those take no part in the road work.
        let roadStyles = featureStyles.map(\.roadStyle)

        // One payload mapping for the whole pre-pass instead of one per
        // feature geometry.
        geometry.data.withUnsafeBytes { bytes in
            for (featureIndex, feature) in layer.features.enumerated() {
                guard roadStyles[featureIndex] != nil, feature.type == .linestring else {
                    continue
                }
                let lines = geometry.lines(of: feature, in: bytes)
                rawLinesByFeatureIndex[featureIndex] = lines.map(floatPoints)
            }
        }

        // Pieces of one street that the tiles ship cut (OSM way boundaries a
        // merge did not close, or cuts the tiler made) are stitched end to
        // end before tessellation, so the street is one ribbon with no seam
        // where the pieces met: no pair of caps, no kerb across the join.
        // Stitching needs a street identity on the geometry (`name`, with the
        // drawing attributes equal); without it nothing is stitched and the
        // pieces draw as they arrive.
        let stitched = RoadStreetStitcher.stitch(linesByFeatureIndex: rawLinesByFeatureIndex,
                                                 featureFacts: featureFacts,
                                                 featureStyles: featureStyles)

        var pointCounts: [RoadConnectionPointKey: Int] = [:]
        // How many features of each road identity end at each point, from
        // the raw polyline ends: an end the tile clip moves onto the
        // boundary is a boundary continuation, which the reader keeps
        // square for the neighbouring tile to meet.
        var endCountsByPoint: [RoadConnectionPointKey: [UInt8: Int]] = [:]
        var linesByFeatureIndex = Array(repeating: [PreparedRoadLine](), count: layer.features.count)
        for (featureIndex, lines) in stitched.enumerated() where lines.isEmpty == false {
            var preparedLines: [PreparedRoadLine] = []
            preparedLines.reserveCapacity(lines.count)
            let identityKey = roadStyles[featureIndex]?.key
            for points in lines {
                let fragments = lineClipper.clip(points: points, tileExtent: tileExtent)
                for fragment in fragments {
                    for point in fragment.points {
                        pointCounts[RoadConnectionPointKey(point: point), default: 0] += 1
                    }
                }
                if let identityKey, let first = points.first, let last = points.last {
                    endCountsByPoint[RoadConnectionPointKey(point: first), default: [:]][identityKey, default: 0] += 1
                    endCountsByPoint[RoadConnectionPointKey(point: last), default: [:]][identityKey, default: 0] += 1
                }
                preparedLines.append(PreparedRoadLine(points: points, exactFragments: fragments))
            }
            linesByFeatureIndex[featureIndex] = preparedLines
        }
        var continuationKeysByPoint: [RoadConnectionPointKey: Set<UInt8>] = [:]
        for (point, counts) in endCountsByPoint {
            let keys = counts.filter { $0.value >= 2 }.keys
            if keys.isEmpty == false {
                continuationKeysByPoint[point] = Set(keys)
            }
        }

        return RoadLayerPrecomputation(sharedPointCounts: pointCounts,
                                       continuationKeysByPoint: continuationKeysByPoint,
                                       linesByFeatureIndex: linesByFeatureIndex)
    }

    static func floatPoints(_ line: LineString) -> [SIMD2<Float>] {
        line.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
    }
}

/// What the readers know about the layer a feature comes from, decided once
/// per layer: whether it takes the separate-road path, and the pre-pass.
struct RoadLayerContext {
    /// The separate-road path: seamless ribbons with the casing under the
    /// fill, sorted by structure and class. Only the road layer, from the
    /// zoom the options name; every other line draws as ground geometry.
    let usesSeparateRoadRendering: Bool
    let precomputation: RoadLayerPrecomputation
}

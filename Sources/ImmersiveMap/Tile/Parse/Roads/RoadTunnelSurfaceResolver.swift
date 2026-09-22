// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// Decides which road surface polygons of a tile are the roof of a tunnel.
///
/// A road line says it runs underground (`ImmersiveMapRoadFacts.structure`).
/// The streetscape polygons built
/// from the road graph (a carriageway or a junction surface) say nothing
/// of the kind, only the `layer` the road had, and a negative layer alone
/// does not mean a tunnel: a street diving under a bridge ships as
/// `layer=-1` too and is in full view from above. So a negative-layer
/// surface counts as a tunnel only when a tunnel centreline of the same
/// layer is in the tile and belongs to it: the same street identity where
/// both carry one, otherwise a vertex of the line inside the polygon. The
/// parser then marks the surface a tunnel roof in its facts
/// (`ImmersiveMapRoadFacts.isTunnelRoof`), the one fact the engine adds to
/// the reading, and the style draws the surface the way its centreline
/// would have been drawn had the surface not clipped it away.
struct RoadTunnelSurfaceResolver {
    /// Indices of the features in `layer` that are tunnel surfaces.
    static func tunnelSurfaceIndices(layer: MvtDecodedLayer,
                                     featureFacts: [ImmersiveMapFeatureFacts],
                                     bytes: UnsafeRawBufferPointer) -> Set<Int> {
        var tunnelLines: [(layer: Int, street: String, points: [SIMD2<Float>])] = []
        var candidates: [Int] = []
        for (index, feature) in layer.features.enumerated() {
            guard let road = featureFacts[index].road else { continue }
            switch feature.type {
            case .linestring where road.structure == .tunnel:
                let points = MvtGeometryDecoder.decodeLines(feature.geometry, in: bytes)
                    .flatMap { $0.map { SIMD2<Float>(Float($0.x), Float($0.y)) } }
                tunnelLines.append((layer: road.layer, street: road.streetIdentity, points: points))
            case .polygon where road.layer < 0 && road.isSurface:
                candidates.append(index)
            default:
                break
            }
        }
        guard tunnelLines.isEmpty == false, candidates.isEmpty == false else { return [] }

        var result = Set<Int>()
        for index in candidates {
            let road = featureFacts[index].road ?? .ground
            let street = road.streetIdentity
            let sameLayer = tunnelLines.filter { $0.layer == road.layer }
            if street.isEmpty == false, sameLayer.contains(where: { $0.street == street }) {
                result.insert(index)
                continue
            }
            // No street to match on one side or the other: the line has to
            // actually run inside the polygon.
            let rings = MvtGeometryDecoder.decodePolygons(layer.features[index].geometry, in: bytes)
                .map { $0.exteriorRing.map { SIMD2<Float>(Float($0.x), Float($0.y)) } }
            // A vertex or a segment midpoint inside the polygon counts: the
            // graph insets the surface behind a portal quad at each end, so
            // the centreline's endpoints sit just outside it and only the
            // stretch between them is in.
            let matches = sameLayer.contains { line in
                (street.isEmpty || line.street.isEmpty)
                    && probes(of: line.points).contains { point in rings.contains { contains(ring: $0, point: point) } }
            }
            if matches {
                result.insert(index)
            }
        }
        return result
    }

    private static func probes(of points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count >= 2 else { return points }
        var result = points
        for index in 1..<points.count {
            result.append((points[index - 1] + points[index]) * 0.5)
        }
        return result
    }

    private static func contains(ring: [SIMD2<Float>], point: SIMD2<Float>) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let pi = ring[i]
            let pj = ring[j]
            if (pi.y > point.y) != (pj.y > point.y) {
                let x = (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x
                if point.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

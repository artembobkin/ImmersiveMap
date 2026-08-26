// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Decides which road surface polygons of a tile are the roof of a tunnel.
///
/// A road line says it runs underground with `brunnel=tunnel`. The
/// streetscape polygons built from the road graph (a carriageway or a
/// junction surface) carry no `brunnel` at all, only the `layer` the road
/// had, and a negative layer alone does not mean a tunnel: a street diving
/// under a bridge ships as `layer=-1` too and is in full view from above.
/// So a negative-layer surface counts as a tunnel only when a tunnel
/// centreline of the same layer is in the tile and belongs to it: the same
/// `street` id where both carry one, otherwise a vertex of the line inside
/// the polygon. The parser then stamps `brunnel=tunnel` on the polygon's
/// attributes before the style sees them, so the surface draws the tunnel
/// look its centreline would have drawn had the surface not clipped it away.
struct RoadTunnelSurfaceResolver {
    /// Indices of the features in `layer` that are tunnel surfaces.
    static func tunnelSurfaceIndices(layer: MvtDecodedLayer,
                                     attributes: [[String: MvtValue]],
                                     bytes: UnsafeRawBufferPointer) -> Set<Int> {
        var tunnelLines: [(layer: Int, street: Int?, points: [SIMD2<Float>])] = []
        var candidates: [Int] = []
        for (index, feature) in layer.features.enumerated() {
            let props = attributes[index]
            let layerValue = intValue(props["layer"]) ?? 0
            switch feature.type {
            case .linestring where props["brunnel"]?.stringValue?.lowercased() == "tunnel":
                let points = MvtGeometryDecoder.decodeLines(feature.geometry, in: bytes)
                    .flatMap { $0.map { SIMD2<Float>(Float($0.x), Float($0.y)) } }
                tunnelLines.append((layer: layerValue, street: intValue(props["street"]), points: points))
            case .polygon where layerValue < 0 && isRoadSurface(props):
                candidates.append(index)
            default:
                break
            }
        }
        guard tunnelLines.isEmpty == false, candidates.isEmpty == false else { return [] }

        var result = Set<Int>()
        for index in candidates {
            let props = attributes[index]
            let layerValue = intValue(props["layer"]) ?? 0
            let street = intValue(props["street"])
            let sameLayer = tunnelLines.filter { $0.layer == layerValue }
            if let street, sameLayer.contains(where: { $0.street == street }) {
                result.insert(index)
                continue
            }
            // No street to match on one side or the other: the line has to
            // actually run inside the polygon.
            let rings = MvtGeometryDecoder.decodePolygons(layer.features[index].geometry, in: bytes)
                .map { $0.exteriorRing.map { SIMD2<Float>(Float($0.x), Float($0.y)) } }
            let matches = sameLayer.contains { line in
                (street == nil || line.street == nil)
                    && line.points.contains { point in rings.contains { contains(ring: $0, point: point) } }
            }
            if matches {
                result.insert(index)
            }
        }
        return result
    }

    private static func isRoadSurface(_ props: [String: MvtValue]) -> Bool {
        let subclass = props["subclass"]?.stringValue?.lowercased()
        return subclass == "junction_area" || subclass == "carriageway_area"
    }

    private static func intValue(_ value: MvtValue?) -> Int? {
        guard let value else { return nil }
        if let number = value.intValue { return Int(number) }
        if let number = value.doubleValue, number.rounded() == number { return Int(number) }
        if let text = value.stringValue { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
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

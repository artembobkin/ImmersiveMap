// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Takes out of a tile's extrusion the buildings a landmark model replaces:
/// the named outlines themselves, and every candidate standing mostly
/// inside one of them. A building is mapped as an outline plus parts, and
/// the parts carry no link to their outline, so standing inside it is what
/// makes a part the replaced building's.
///
/// "Mostly" is more than half of the candidate's lid area. A part of the
/// building lies wholly inside, a neighbour touching it from outside barely
/// at all. The share matters for the coarse tiles, whose buildings the
/// tileset merges into blocks: a block that is mostly the landmark goes, one
/// that only clips its edge stays. The share is measured on the lid's
/// triangles, each split in four, by where each piece's centroid falls.
///
/// Works per tile on the geometry the tile carries: the outline is clipped
/// by the tile's buffer exactly as its parts are.
struct ReplacedBuildingFilter {
    /// A replaced outline in render space: its rings and their bounds.
    private struct Outline {
        let rings: [[SIMD2<Float>]]
        let minimum: SIMD2<Float>
        let maximum: SIMD2<Float>
    }

    /// The share of a candidate's lid inside an outline past which it goes.
    private static let replacedShare: Float = 0.5

    private let replacedIDs: Set<UInt64>
    private var outlines: [Outline] = []

    /// Only the outlines replaced at `tileZoom` or earlier take part: below
    /// a landmark's zoom its building stays in the tile.
    init(replacedIDs: [UInt64: Int], tileZoom: Int) {
        self.replacedIDs = Set(replacedIDs.compactMap { id, zoom in zoom <= tileZoom ? id : nil })
    }

    var isActive: Bool {
        replacedIDs.isEmpty == false
    }

    func replaces(_ featureID: UInt64) -> Bool {
        replacedIDs.contains(featureID)
    }

    /// Records a replaced outline's polygons. The parser records every one
    /// it meets, whatever the style says, so an outline the style leaves
    /// flat still takes its parts out.
    mutating func record(outline polygons: MultiPolygon) {
        for polygon in polygons {
            var rings = [ringInRenderSpace(polygon.exteriorRing)]
            rings.append(contentsOf: polygon.interiorRings.map(ringInRenderSpace))
            guard let exterior = rings.first, exterior.count >= 3 else { continue }
            let minimum = exterior.reduce(exterior[0], simd_min)
            let maximum = exterior.reduce(exterior[0], simd_max)
            outlines.append(Outline(rings: rings, minimum: minimum, maximum: maximum))
        }
    }

    /// The candidates the landmarks leave standing.
    func remaining(_ candidates: [BuildingExtrusionCandidate]) -> [BuildingExtrusionCandidate] {
        guard isActive else { return candidates }
        return candidates.filter { candidate in
            if replacedIDs.contains(candidate.buildingId) {
                return false
            }
            let exterior = candidate.clippedExterior
            guard exterior.isEmpty == false else { return true }
            let minimum = exterior.reduce(exterior[0], simd_min)
            let maximum = exterior.reduce(exterior[0], simd_max)
            let reached = outlines.filter { outline in
                all(minimum .<= outline.maximum) && all(outline.minimum .<= maximum)
            }
            guard reached.isEmpty == false else { return true }
            return Self.shareInside(candidate, outlines: reached) <= Self.replacedShare
        }
    }

    private func ringInRenderSpace(_ ring: [Point]) -> [SIMD2<Float>] {
        ring.map { point in
            TileCoordinateSpace.renderPoint(SIMD2<Float>(Float(point.x), Float(point.y)))
        }
    }

    /// The share of the lid's area inside any of the outlines. A lid with no
    /// triangles counts as its exterior's vertex mean, wholly in or out.
    private static func shareInside(_ candidate: BuildingExtrusionCandidate, outlines: [Outline]) -> Float {
        func isInside(_ point: SIMD2<Float>) -> Bool {
            outlines.contains { outline in contains(outline.rings, point) }
        }

        let roof = candidate.roof
        var totalArea: Float = 0
        var insideArea: Float = 0
        var index = 0
        while index + 2 < roof.indices.count {
            let a = SIMD2<Float>(roof.vertices[Int(roof.indices[index])])
            let b = SIMD2<Float>(roof.vertices[Int(roof.indices[index + 1])])
            let c = SIMD2<Float>(roof.vertices[Int(roof.indices[index + 2])])
            index += 3
            let ab = b - a
            let ac = c - a
            let area = abs(ab.x * ac.y - ab.y * ac.x)
            guard area > 0 else { continue }
            totalArea += area
            // The midpoint split: four triangles of a quarter of the area,
            // the corner three and the middle one.
            let mab = (a + b) * 0.5
            let mbc = (b + c) * 0.5
            let mca = (c + a) * 0.5
            let pieces = [(a + mab + mca) / 3,
                          (mab + b + mbc) / 3,
                          (mca + mbc + c) / 3,
                          (mab + mbc + mca) / 3]
            for centroid in pieces where isInside(centroid) {
                insideArea += area * 0.25
            }
        }
        guard totalArea > 0 else {
            let exterior = candidate.clippedExterior
            let mean = exterior.reduce(SIMD2<Float>.zero, +) / Float(exterior.count)
            return isInside(mean) ? 1 : 0
        }
        return insideArea / totalArea
    }

    /// Even-odd over every ring: inside the exterior and outside its holes.
    private static func contains(_ rings: [[SIMD2<Float>]], _ point: SIMD2<Float>) -> Bool {
        var isInside = false
        for ring in rings where ring.count >= 3 {
            var previous = ring[ring.count - 1]
            for current in ring {
                if (current.y > point.y) != (previous.y > point.y) {
                    let crossingX = current.x
                        + (point.y - current.y) * (previous.x - current.x) / (previous.y - current.y)
                    if point.x < crossingX {
                        isInside.toggle()
                    }
                }
                previous = current
            }
        }
        return isInside
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The roof a point of the tile stands under: the top of the tallest
/// extruded volume whose footprint holds it, in the tile units the
/// extrusion mesh is built in, so a label lifted by it lands on the roof
/// the tile draws. Built from the candidates the resolver kept, after the
/// whole tile is read, so a clamped envelope answers its clamped height and
/// a dropped volume answers nothing. A point in a courtyard (an interior
/// ring) is not under that building's roof.
struct BuildingRoofLookup {
    private struct Volume {
        let exterior: [SIMD2<Float>]
        let interiors: [[SIMD2<Float>]]
        let minimum: SIMD2<Float>
        let maximum: SIMD2<Float>
        let topHeight: Float
    }

    /// The grid the footprints are bucketed in, in tile units: a building
    /// is rarely wider than a cell, so a point meets a handful of volumes.
    private static let cellSize: Float = 256

    private var volumes: [Volume] = []
    private var cells: [Int64: [Int]] = [:]

    /// `candidates` are the volumes the tile draws.
    init(candidates: [BuildingExtrusionCandidate]) {
        volumes.reserveCapacity(candidates.count)
        for candidate in candidates {
            add(candidate)
        }
    }

    private mutating func add(_ candidate: BuildingExtrusionCandidate) {
        guard candidate.clippedExterior.count >= 3 else {
            return
        }
        do {
            var minimum = candidate.clippedExterior[0]
            var maximum = minimum
            for point in candidate.clippedExterior {
                minimum = simd_min(minimum, point)
                maximum = simd_max(maximum, point)
            }
            let index = volumes.count
            volumes.append(Volume(exterior: candidate.clippedExterior,
                                  interiors: candidate.clippedInteriors,
                                  minimum: minimum,
                                  maximum: maximum,
                                  topHeight: candidate.topHeight))
            let minCell = Self.cell(of: minimum)
            let maxCell = Self.cell(of: maximum)
            for row in minCell.y...maxCell.y {
                for column in minCell.x...maxCell.x {
                    cells[Self.key(column: column, row: row), default: []].append(index)
                }
            }
        }
    }

    var isEmpty: Bool {
        volumes.isEmpty
    }

    /// The roof height over a point given in tile space (y down, as the
    /// labels carry their anchors): the top of the tallest volume holding
    /// it, zero where no volume does.
    func roofHeight(atTilePoint tilePoint: SIMD2<Int16>) -> Float {
        let point = TileCoordinateSpace.renderPoint(SIMD2<Float>(Float(tilePoint.x), Float(tilePoint.y)))
        let cell = Self.cell(of: point)
        guard let indices = cells[Self.key(column: cell.x, row: cell.y)] else {
            return 0
        }
        var roof: Float = 0
        for index in indices {
            let volume = volumes[index]
            guard volume.topHeight > roof,
                  point.x >= volume.minimum.x, point.x <= volume.maximum.x,
                  point.y >= volume.minimum.y, point.y <= volume.maximum.y,
                  BuildingExtrusionResolver.pointInRing(point, ring: volume.exterior),
                  volume.interiors.contains(where: { BuildingExtrusionResolver.pointInRing(point, ring: $0) }) == false else {
                continue
            }
            roof = volume.topHeight
        }
        return roof
    }

    private static func cell(of point: SIMD2<Float>) -> SIMD2<Int64> {
        SIMD2(Int64((point.x / cellSize).rounded(.down)), Int64((point.y / cellSize).rounded(.down)))
    }

    private static func key(column: Int64, row: Int64) -> Int64 {
        row &* 1_000_003 &+ column
    }
}

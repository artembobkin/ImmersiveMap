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
    /// The roof over a point: its height, and whether the volume it comes
    /// from is one a landmark model replaces, so the frame takes the
    /// drawn model's top in its place.
    struct Roof: Equatable {
        static let none = Roof(height: 0, isReplaced: false)

        let height: Float
        let isReplaced: Bool
    }

    private struct Volume {
        let exterior: [SIMD2<Float>]
        let interiors: [[SIMD2<Float>]]
        let minimum: SIMD2<Float>
        let maximum: SIMD2<Float>
        let topHeight: Float
        let isReplaced: Bool
    }

    /// The grid the footprints are bucketed in, in tile units: a building
    /// is rarely wider than a cell, so a point meets a handful of volumes.
    private static let cellSize: Float = 256

    private var volumes: [Volume] = []
    private var cells: [Int64: [Int]] = [:]

    /// `candidates` are the volumes the tile draws, `replacedCandidates`
    /// the ones a landmark model stands in for.
    init(candidates: [BuildingExtrusionCandidate],
         replacedCandidates: [BuildingExtrusionCandidate] = []) {
        volumes.reserveCapacity(candidates.count + replacedCandidates.count)
        for candidate in candidates {
            add(candidate, isReplaced: false)
        }
        for candidate in replacedCandidates {
            add(candidate, isReplaced: true)
        }
    }

    private mutating func add(_ candidate: BuildingExtrusionCandidate, isReplaced: Bool) {
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
                                  topHeight: candidate.topHeight,
                                  isReplaced: isReplaced))
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
    /// labels carry their anchors), zero where no volume holds it.
    func roofHeight(atTilePoint tilePoint: SIMD2<Int16>) -> Float {
        roof(atTilePoint: tilePoint).height
    }

    /// The roof over a point given in tile space: the tallest volume
    /// holding it, `.none` where no volume does.
    func roof(atTilePoint tilePoint: SIMD2<Int16>) -> Roof {
        let point = TileCoordinateSpace.renderPoint(SIMD2<Float>(Float(tilePoint.x), Float(tilePoint.y)))
        let cell = Self.cell(of: point)
        guard let indices = cells[Self.key(column: cell.x, row: cell.y)] else {
            return .none
        }
        var roof = Roof.none
        for index in indices {
            let volume = volumes[index]
            guard volume.topHeight > roof.height,
                  point.x >= volume.minimum.x, point.x <= volume.maximum.x,
                  point.y >= volume.minimum.y, point.y <= volume.maximum.y,
                  BuildingExtrusionResolver.pointInRing(point, ring: volume.exterior),
                  volume.interiors.contains(where: { BuildingExtrusionResolver.pointInRing(point, ring: $0) }) == false else {
                continue
            }
            roof = Roof(height: volume.topHeight, isReplaced: volume.isReplaced)
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

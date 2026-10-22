// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Where the trees of a tile stand: one at most in every cell of a lattice
/// laid over the fills that grow them (`TreeFillStyle`), moved within its
/// cell, turned and sized by a hash of the cell, so the same ground grows
/// the same trees at every parse and in every tile zoom. The lattice is
/// fixed in the world, in the tile units of `latticeZoom`, so a z14 tile
/// and its z15 children stand their trees at the same points and a change
/// of zoom moves none. A cell's tree is kept when its point lies in the
/// fill, inside the tile, on no building's footprint and off every road
/// of the ground by the fill's clearance (`TreeFillStyle.roadClearanceMetres`).
///
/// Every tree draws a priority from its hash, and a tile's trees are
/// sorted by it, so the frame thins a tile by drawing the first of them,
/// and a tile that keeps at most `maximumCount` keeps the first too: what
/// the frame shows at a far zoom is a subset of what it shows close.
enum TreeScatter {
    /// The tile zoom whose tile units the lattice is laid in.
    static let latticeZoom = 16
    /// The tile zoom whose tile's latitude sizes the lattice's cell and
    /// the trees: the building coverage's grid, so a tile and every
    /// descendant of its ancestor there read one latitude. The cell's
    /// size in lattice units follows the latitude, and the lattice is
    /// counted from the world's origin, hundreds of millions of units
    /// away: a cell sized by each tile's own latitude moved the lattice
    /// by hundreds of cells between a tile and its children, and the
    /// coverage, drawing the one or the others for the same ground,
    /// changed the wood with every move of the camera.
    static let latitudeZoom = BuildingCoveragePlanner.minimumSourceZoom

    /// A fill's polygons in tile space, and the trees it grows.
    struct Area {
        let polygons: MultiPolygon
        let style: TreeFillStyle
    }

    /// A road of the ground the trees keep off: its centreline in render
    /// space and half the width the style draws it with, in the tile units
    /// of `latticeZoom`. The style states a ribbon's width in the same
    /// tile units at every zoom, so read at the tile's own zoom it would be
    /// twice as wide on the ground in a z14 tile as in a z15 one, and the
    /// two would keep different trees off the same path. Read as units of
    /// one zoom, the width is one width on the ground.
    struct Road {
        let points: [SIMD2<Float>]
        let halfWidth: Float
    }

    /// A polygon no tree stands in, in render space: a building's
    /// footprint, a pond, a pitch. Its holes stand trees again: the
    /// island in the lake, the courtyard.
    struct Footprint {
        let exterior: [SIMD2<Float>]
        let interiors: [[SIMD2<Float>]]
    }

    /// What the trees keep off: the footprints and the roads.
    struct Obstacles {
        var footprints: [Footprint] = []
        var roads: [Road] = []
    }

    /// The share of a cell its tree may stand away from the cell's
    /// centre, each way: never at the edge, so two neighbours never touch.
    private static let jitterSpan: Float = 0.8

    /// The trees of `areas` in `tile`, sorted by priority and cut at
    /// `maximumCount`, off `obstacles`.
    static func scatter(areas: [Area],
                        tile: Tile,
                        obstacles: Obstacles,
                        maximumCount: Int) -> [TreeInstance] {
        guard areas.isEmpty == false, maximumCount > 0 else { return [] }
        let extent = TileCoordinateSpace.tileExtent
        // The scale at the latitude of the tile's ancestor on the
        // coverage's grid (`latitudeZoom`): the Web-Mercator metre,
        // inflated toward the poles as the footprints are.
        let latitudeTile = tile.findParentTile(atZoom: latitudeZoom) ?? tile
        let latitude = ImmersiveMapProjection.latitude(
            fromNormalizedWorldY: (Double(latitudeTile.y) + 0.5) / Double(1 << latitudeTile.z))
        let unitsPerMetreAtLattice = Float(Double(TileCoordinateSpace.tileExtentDouble) * pow(2.0, Double(latticeZoom))
            / (ImmersiveMapProjection.earthCircumferenceMeters * cos(latitude)))
        let unitsPerMetre = unitsPerMetreAtLattice * powf(2, Float(tile.z - latticeZoom))
        // Tile units of this tile per lattice unit, and the tile's origin
        // on the lattice.
        let latticePerTileUnit = pow(2.0, Double(latticeZoom - tile.z))
        let latticeOrigin = SIMD2<Double>(Double(tile.x), Double(tile.y)) * TileCoordinateSpace.tileExtentDouble * latticePerTileUnit

        let clearances = areas.map { $0.style.roadClearanceMetres * unitsPerMetre }
        let obstacleIndex = ObstacleIndex(obstacles: obstacles,
                                          roadWidthScale: Float(1 / latticePerTileUnit),
                                          maximumClearance: clearances.max() ?? 0)
        var candidates: [(priority: Float, instance: TreeInstance)] = []
        for (areaIndex, area) in areas.enumerated() {
            let cell = area.style.spacingMetres * unitsPerMetreAtLattice
            guard cell > 0, cell.isFinite else { continue }
            let salt = area.style.lattice
            let clearance = clearances[areaIndex]
            for polygon in area.polygons {
                let exterior = polygon.exteriorRing.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
                guard exterior.count >= 3 else { continue }
                let interiors = polygon.interiorRings.map { ring in ring.map { SIMD2<Float>(Float($0.x), Float($0.y)) } }
                // The cells the polygon's bounds cover, on the lattice,
                // kept to the tile: a tree outside it is its neighbour's.
                var minimum = exterior[0]
                var maximum = exterior[0]
                for point in exterior {
                    minimum = simd_min(minimum, point)
                    maximum = simd_max(maximum, point)
                }
                minimum = simd_max(minimum, SIMD2<Float>(repeating: 0))
                maximum = simd_min(maximum, SIMD2<Float>(repeating: extent))
                guard minimum.x < maximum.x, minimum.y < maximum.y else { continue }
                let cellStart = SIMD2<Int64>(Int64((latticeOrigin.x + Double(minimum.x) * latticePerTileUnit) / Double(cell)),
                                             Int64((latticeOrigin.y + Double(minimum.y) * latticePerTileUnit) / Double(cell)))
                let cellEnd = SIMD2<Int64>(Int64((latticeOrigin.x + Double(maximum.x) * latticePerTileUnit) / Double(cell)),
                                           Int64((latticeOrigin.y + Double(maximum.y) * latticePerTileUnit) / Double(cell)))
                guard cellEnd.x >= cellStart.x, cellEnd.y >= cellStart.y,
                      (cellEnd.x - cellStart.x + 1) * (cellEnd.y - cellStart.y + 1) < 1 << 24 else { continue }
                for cellY in cellStart.y...cellEnd.y {
                    for cellX in cellStart.x...cellEnd.x {
                        let hash = Self.hash(UInt32(truncatingIfNeeded: cellX),
                                             UInt32(truncatingIfNeeded: cellY),
                                             salt)
                        let jitter = Self.jitter(hash)
                        let latticePoint = SIMD2<Double>((Double(cellX) + 0.5 + Double(jitter.x)) * Double(cell),
                                                         (Double(cellY) + 0.5 + Double(jitter.y)) * Double(cell))
                        let tilePoint = SIMD2<Float>((latticePoint - latticeOrigin) / latticePerTileUnit)
                        guard tilePoint.x >= 0, tilePoint.x < extent, tilePoint.y >= 0, tilePoint.y < extent,
                              Self.contains(tilePoint, exterior: exterior, interiors: interiors) else { continue }
                        let renderPoint = TileCoordinateSpace.renderPoint(tilePoint)
                        guard obstacleIndex.covers(renderPoint, roadClearance: clearance) == false else { continue }
                        let second = Self.hash(hash, 0x9E37_79B9, salt)
                        let size = Float(second & 0xFFFF) / 65535
                        let height = area.style.minimumHeightMetres
                            + (area.style.maximumHeightMetres - area.style.minimumHeightMetres) * size
                        candidates.append((priority: Float((second >> 16) & 0xFFFF) / 65535,
                                           instance: TreeInstance(position: renderPoint,
                                                                  height: height * unitsPerMetre,
                                                                  rotation: Float(hash >> 24) / 255,
                                                                  tint: Float((hash >> 16) & 0xFF) / 255)))
                    }
                }
            }
        }
        candidates.sort { lhs, rhs in
            lhs.priority < rhs.priority || (lhs.priority == rhs.priority && lhs.instance.packed < rhs.instance.packed)
        }
        return candidates.prefix(maximumCount).map(\.instance)
    }

    /// A 32-bit mix of a cell and a salt: the one source of every tree's
    /// chance, so the result is the same on every machine.
    static func hash(_ x: UInt32, _ y: UInt32, _ salt: UInt32) -> UInt32 {
        var h = x &* 0x8DA6_B343
        h ^= y &* 0xD816_3841
        h ^= salt &* 0xCB1A_B31F
        h ^= h >> 16
        h &*= 0x7FEB_352D
        h ^= h >> 15
        h &*= 0x846C_A68B
        h ^= h >> 16
        return h
    }

    /// Where in its cell a tree stands, each way within `jitterSpan` of
    /// the centre, from the hash's low bits.
    private static func jitter(_ hash: UInt32) -> SIMD2<Float> {
        let x = Float(hash & 0xFF) / 255 - 0.5
        let y = Float((hash >> 8) & 0xFF) / 255 - 0.5
        return SIMD2<Float>(x, y) * jitterSpan
    }

    /// Whether a point lies in a polygon: in its exterior and in none of
    /// its holes, by the even-odd rule, in whatever space the rings are.
    static func contains(_ point: SIMD2<Float>, exterior: [SIMD2<Float>], interiors: [[SIMD2<Float>]]) -> Bool {
        guard contains(point, ring: exterior) else { return false }
        for interior in interiors where contains(point, ring: interior) {
            return false
        }
        return true
    }

    static func contains(_ point: SIMD2<Float>, ring: [SIMD2<Float>]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var previous = ring[ring.count - 1]
        for current in ring {
            if (current.y > point.y) != (previous.y > point.y) {
                let x = previous.x + (point.y - previous.y) / (current.y - previous.y) * (current.x - previous.x)
                if point.x < x {
                    inside.toggle()
                }
            }
            previous = current
        }
        return inside
    }

    /// The footprints and the roads the trees keep off, bucketed over the
    /// tile so a point asks only the footprints and the road segments
    /// whose bounds reach its bucket. A segment's bounds are widened by the
    /// road's half width and the widest clearance any fill asks, so the
    /// bucket holds every segment a point in it could be too near.
    private struct ObstacleIndex {
        private static let gridSize = 16

        private struct Segment {
            let start: SIMD2<Float>
            let end: SIMD2<Float>
            let halfWidth: Float
        }

        private let footprints: [Footprint]
        private let bounds: [(minimum: SIMD2<Float>, maximum: SIMD2<Float>)]
        private let segments: [Segment]
        private let footprintBuckets: [[Int32]]
        private let segmentBuckets: [[Int32]]

        /// `roadWidthScale` turns a road's half width, in the lattice
        /// zoom's tile units, into the tile's own.
        init(obstacles: Obstacles, roadWidthScale: Float, maximumClearance: Float) {
            let footprints = obstacles.footprints
            var bounds: [(minimum: SIMD2<Float>, maximum: SIMD2<Float>)] = []
            bounds.reserveCapacity(footprints.count)
            var footprintBuckets: [[Int32]] = Array(repeating: [], count: Self.gridSize * Self.gridSize)
            for (index, footprint) in footprints.enumerated() {
                guard let first = footprint.exterior.first else {
                    bounds.append((.zero, .zero))
                    continue
                }
                var minimum = first
                var maximum = first
                for point in footprint.exterior {
                    minimum = simd_min(minimum, point)
                    maximum = simd_max(maximum, point)
                }
                bounds.append((minimum, maximum))
                Self.forEachBucket(from: minimum, to: maximum) { bucket in
                    footprintBuckets[bucket].append(Int32(index))
                }
            }

            var segments: [Segment] = []
            var segmentBuckets: [[Int32]] = Array(repeating: [], count: Self.gridSize * Self.gridSize)
            for road in obstacles.roads {
                let halfWidth = road.halfWidth * roadWidthScale
                let padding = SIMD2<Float>(repeating: halfWidth + max(maximumClearance, 0))
                for (start, end) in zip(road.points, road.points.dropFirst()) {
                    let index = Int32(segments.count)
                    segments.append(Segment(start: start, end: end, halfWidth: halfWidth))
                    Self.forEachBucket(from: simd_min(start, end) - padding, to: simd_max(start, end) + padding) { bucket in
                        segmentBuckets[bucket].append(index)
                    }
                }
            }
            self.footprints = footprints
            self.bounds = bounds
            self.footprintBuckets = footprintBuckets
            self.segments = segments
            self.segmentBuckets = segmentBuckets
        }

        private static func bucket(of point: SIMD2<Float>) -> (x: Int, y: Int) {
            let scale = Float(gridSize) / TileCoordinateSpace.tileExtent
            let x = min(max(Int(point.x * scale), 0), gridSize - 1)
            let y = min(max(Int(point.y * scale), 0), gridSize - 1)
            return (x, y)
        }

        private static func forEachBucket(from minimum: SIMD2<Float>, to maximum: SIMD2<Float>, _ body: (Int) -> Void) {
            let start = bucket(of: minimum)
            let end = bucket(of: maximum)
            for y in start.y...end.y {
                for x in start.x...end.x {
                    body(y * gridSize + x)
                }
            }
        }

        /// Whether a point is on a footprint (and not in one of its holes),
        /// or nearer a road's centreline than its half width plus
        /// `roadClearance`.
        func covers(_ point: SIMD2<Float>, roadClearance: Float) -> Bool {
            let bucket = Self.bucket(of: point)
            let bucketIndex = bucket.y * Self.gridSize + bucket.x
            for index in footprintBuckets[bucketIndex] {
                let box = bounds[Int(index)]
                guard point.x >= box.minimum.x, point.x <= box.maximum.x,
                      point.y >= box.minimum.y, point.y <= box.maximum.y else { continue }
                let footprint = footprints[Int(index)]
                if TreeScatter.contains(point, exterior: footprint.exterior, interiors: footprint.interiors) {
                    return true
                }
            }
            for index in segmentBuckets[bucketIndex] {
                let segment = segments[Int(index)]
                let reach = segment.halfWidth + roadClearance
                if Self.squaredDistance(from: point, toSegment: segment.start, segment.end) <= reach * reach {
                    return true
                }
            }
            return false
        }

        private static func squaredDistance(from point: SIMD2<Float>,
                                            toSegment start: SIMD2<Float>, _ end: SIMD2<Float>) -> Float {
            let direction = end - start
            let length = simd_length_squared(direction)
            guard length > 1e-6 else { return simd_length_squared(point - start) }
            let t = min(max(simd_dot(point - start, direction) / length, 0), 1)
            return simd_length_squared(point - (start + direction * t))
        }
    }
}

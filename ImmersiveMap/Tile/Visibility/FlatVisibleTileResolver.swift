// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  FlatVisibleTileResolver.swift
//  ImmersiveMap
//

import simd

enum FlatVisibleTileResolver {
    private static let wrapLoops: [Int8] = [-1, 0, 1]
    static let planeIntersectionTolerance: Float = 1e-5

    static func resolveVisibleTiles(targetZoom: Int,
                                    center: Center,
                                    flatRenderState: FlatRenderState,
                                    cameraMatrix: matrix_float4x4?,
                                    maxRelativeDistance: Int = VisibleTilesPreprocessor.defaultMaxVisibleRelativeDistance) -> Set<VisibleTile> {
        guard targetZoom >= 0,
              let coveragePolygon = makeCoveragePolygon(cameraMatrix: cameraMatrix) else {
            return []
        }

        let tilesCount = 1 << targetZoom
        let mapSize = flatRenderState.renderMapSize
        let tileSize = mapSize / Double(tilesCount)
        guard mapSize.isFinite, tileSize.isFinite, tileSize > 0 else {
            return []
        }

        var visibleTiles: Set<VisibleTile> = []
        visibleTiles.reserveCapacity(coveragePolygon.vertices.count * wrapLoops.count * 4)

        for loop in wrapLoops {
            guard let candidateRange = makeCandidateRange(targetZoom: targetZoom,
                                                          coverageBounds: coveragePolygon.bounds,
                                                          flatRenderState: flatRenderState,
                                                          loop: loop,
                                                          center: center,
                                                          maxRelativeDistance: maxRelativeDistance) else {
                continue
            }

            insertRowTiles(into: &visibleTiles,
                           coveragePolygon: coveragePolygon,
                           candidateRange: candidateRange,
                           targetZoom: targetZoom,
                           loop: loop,
                           flatRenderState: flatRenderState)
        }

        return visibleTiles
    }

    // Сканлайн по строкам кандидатов: полигон покрытия выпуклый, поэтому его
    // пересечение с горизонтальной полосой строки - один интервал по x, и все
    // тайлы строки в этом интервале пересекают полигон, остальные - нет.
    // Заменяет пер-тайловые полигон-тесты (O(кандидаты × рёбра) с аллокациями
    // на каждый тест) на O(строки × рёбра) без аллокаций.
    private static func insertRowTiles(into visibleTiles: inout Set<VisibleTile>,
                                       coveragePolygon: CoveragePolygon,
                                       candidateRange: TileCandidateRange,
                                       targetZoom: Int,
                                       loop: Int8,
                                       flatRenderState: FlatRenderState) {
        let tilesCount = 1 << targetZoom
        let mapSize = flatRenderState.renderMapSize
        let tileSize = mapSize / Double(tilesCount)
        let halfMapSize = mapSize * 0.5
        let xOffset = -halfMapSize + flatRenderState.pan.x * halfMapSize + Double(loop) * mapSize
        let yOffset = -halfMapSize - flatRenderState.pan.y * halfMapSize
        let tolerance = Double(planeIntersectionTolerance)

        for y in candidateRange.minY...candidateRange.maxY {
            let rowFromBottom = Double((tilesCount - 1) - y)
            let slabMinY = Float(yOffset + rowFromBottom * tileSize - tolerance)
            let slabMaxY = Float(yOffset + (rowFromBottom + 1) * tileSize + tolerance)
            guard let xRange = coveragePolygon.horizontalSlabXRange(slabMinY: slabMinY,
                                                                    slabMaxY: slabMaxY) else {
                continue
            }

            let minColumn = Int(floor((Double(xRange.lowerBound) - xOffset - tolerance) / tileSize))
            let maxColumn = Int(floor((Double(xRange.upperBound) - xOffset + tolerance) / tileSize))
            let firstX = max(minColumn, candidateRange.minX)
            let lastX = min(maxColumn, candidateRange.maxX)
            guard firstX <= lastX else {
                continue
            }

            for x in firstX...lastX {
                visibleTiles.insert(VisibleTile(x: x, y: y, z: targetZoom, loop: loop))
            }
        }
    }

    // Internal для тестов: property-тесты сверяют сканлайн с эталонной
    // пер-тайловой проверкой на том же полигоне.
    static func makeCoveragePolygon(cameraMatrix: matrix_float4x4?) -> CoveragePolygon? {
        guard let cameraMatrix else {
            return nil
        }

        let inverseCameraMatrix = simd_inverse(cameraMatrix)
        let frustumCorners = clipSpaceCorners.compactMap { unprojectClipSpacePoint($0, inverseCameraMatrix: inverseCameraMatrix) }
        guard frustumCorners.count == clipSpaceCorners.count else {
            return nil
        }

        var intersections: [SIMD2<Float>] = []
        intersections.reserveCapacity(frustumEdges.count * 2)

        for edge in frustumEdges {
            appendPlaneIntersections(from: frustumCorners[edge.start],
                                     to: frustumCorners[edge.end],
                                     intersections: &intersections)
        }

        let sortedVertices = sortVerticesClockwise(intersections)
        guard sortedVertices.count >= 3,
              abs(polygonSignedArea(sortedVertices)) > planeIntersectionTolerance else {
            return nil
        }

        return CoveragePolygon(vertices: sortedVertices)
    }

    private static func unprojectClipSpacePoint(_ point: SIMD3<Float>,
                                                inverseCameraMatrix: matrix_float4x4) -> SIMD3<Float>? {
        let homogenous = inverseCameraMatrix * SIMD4<Float>(point.x, point.y, point.z, 1)
        guard homogenous.w.isFinite, abs(homogenous.w) > planeIntersectionTolerance else {
            return nil
        }

        let worldPoint = homogenous / homogenous.w
        guard worldPoint.x.isFinite, worldPoint.y.isFinite, worldPoint.z.isFinite else {
            return nil
        }

        return SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
    }

    private static func appendPlaneIntersections(from start: SIMD3<Float>,
                                                 to end: SIMD3<Float>,
                                                 intersections: inout [SIMD2<Float>]) {
        appendIfPointLiesOnFlatPlane(start, intersections: &intersections)
        appendIfPointLiesOnFlatPlane(end, intersections: &intersections)

        let denominator = start.z - end.z
        guard abs(denominator) > planeIntersectionTolerance else {
            return
        }

        let t = start.z / denominator
        guard t >= -planeIntersectionTolerance, t <= 1 + planeIntersectionTolerance else {
            return
        }

        let clampedT = min(max(t, 0), 1)
        let point = start + (end - start) * clampedT
        guard abs(point.z) <= planeIntersectionTolerance else {
            return
        }

        appendUnique(SIMD2<Float>(point.x, point.y), intersections: &intersections)
    }

    private static func appendIfPointLiesOnFlatPlane(_ point: SIMD3<Float>,
                                                     intersections: inout [SIMD2<Float>]) {
        guard abs(point.z) <= planeIntersectionTolerance else {
            return
        }
        appendUnique(SIMD2<Float>(point.x, point.y), intersections: &intersections)
    }

    private static func appendUnique(_ point: SIMD2<Float>,
                                     intersections: inout [SIMD2<Float>]) {
        for existing in intersections {
            if simd_length_squared(existing - point) <= planeIntersectionTolerance * planeIntersectionTolerance {
                return
            }
        }
        intersections.append(point)
    }

    private static func sortVerticesClockwise(_ vertices: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard vertices.count >= 3 else {
            return []
        }

        let centroid = vertices.reduce(SIMD2<Float>.zero, +) / Float(vertices.count)
        return vertices.sorted { lhs, rhs in
            let lhsAngle = atan2(lhs.y - centroid.y, lhs.x - centroid.x)
            let rhsAngle = atan2(rhs.y - centroid.y, rhs.x - centroid.x)

            if abs(lhsAngle - rhsAngle) > planeIntersectionTolerance {
                return lhsAngle < rhsAngle
            }

            if abs(lhs.x - rhs.x) > planeIntersectionTolerance {
                return lhs.x < rhs.x
            }

            return lhs.y < rhs.y
        }
    }

    private static func polygonSignedArea(_ vertices: [SIMD2<Float>]) -> Float {
        guard vertices.count >= 3 else {
            return 0
        }

        var area: Float = 0
        for index in vertices.indices {
            let nextIndex = (index + 1) % vertices.count
            area += vertices[index].x * vertices[nextIndex].y - vertices[nextIndex].x * vertices[index].y
        }
        return area * 0.5
    }

    private static func makeCandidateRange(targetZoom: Int,
                                           coverageBounds: CoverageBounds,
                                           flatRenderState: FlatRenderState,
                                           loop: Int8,
                                           center: Center,
                                           maxRelativeDistance: Int) -> TileCandidateRange? {
        let tilesCount = 1 << targetZoom
        guard tilesCount > 0 else {
            return nil
        }

        let mapSize = flatRenderState.renderMapSize
        let tileSize = mapSize / Double(tilesCount)
        let halfMapSize = mapSize * 0.5
        let panXOffset = flatRenderState.pan.x * halfMapSize
        let panYOffset = flatRenderState.pan.y * halfMapSize
        let xOffset = -halfMapSize + panXOffset + Double(loop) * mapSize
        let yOffset = -halfMapSize - panYOffset
        let padding = max(tileSize * 1e-6, 1e-6)

        let minColumn = Int(floor((Double(coverageBounds.minX) - xOffset - padding) / tileSize))
        let maxColumn = Int(floor((Double(coverageBounds.maxX) - xOffset + padding) / tileSize))
        let minRowFromBottom = Int(floor((Double(coverageBounds.minY) - yOffset - padding) / tileSize))
        let maxRowFromBottom = Int(floor((Double(coverageBounds.maxY) - yOffset + padding) / tileSize))

        // Кламп радиусом дистанционного фильтра препроцессора: всё дальше
        // maxRelativeDistance от центра он выбрасывает, а bbox полигона,
        // вытянутого к горизонту при большом наклоне камеры, накрывает
        // миллионы тайлов-кандидатов. Центр переводится в систему текущей
        // мировой копии (`loop`), как в VisibleTileRelativeDistance.
        let centerTileX = Int(center.tileX) - Int(loop) * tilesCount
        let centerTileY = Int(center.tileY)

        let minX = max(minColumn, centerTileX - maxRelativeDistance)
        let maxX = min(maxColumn, centerTileX + maxRelativeDistance)
        let minY = max((tilesCount - 1) - maxRowFromBottom, centerTileY - maxRelativeDistance)
        let maxY = min((tilesCount - 1) - minRowFromBottom, centerTileY + maxRelativeDistance)

        return TileCandidateRange(minX: clamp(minX, lowerBound: 0, upperBound: tilesCount - 1),
                                  maxX: clamp(maxX, lowerBound: 0, upperBound: tilesCount - 1),
                                  minY: clamp(minY, lowerBound: 0, upperBound: tilesCount - 1),
                                  maxY: clamp(maxY, lowerBound: 0, upperBound: tilesCount - 1))
            .normalized
    }

    private static func clamp(_ value: Int,
                              lowerBound: Int,
                              upperBound: Int) -> Int {
        min(max(value, lowerBound), upperBound)
    }

    private static let clipSpaceCorners: [SIMD3<Float>] = [
        SIMD3<Float>(-1, -1, 0),
        SIMD3<Float>(1, -1, 0),
        SIMD3<Float>(1, 1, 0),
        SIMD3<Float>(-1, 1, 0),
        SIMD3<Float>(-1, -1, 1),
        SIMD3<Float>(1, -1, 1),
        SIMD3<Float>(1, 1, 1),
        SIMD3<Float>(-1, 1, 1)
    ]

    private static let frustumEdges: [(start: Int, end: Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 0),
        (4, 5), (5, 6), (6, 7), (7, 4),
        (0, 4), (1, 5), (2, 6), (3, 7)
    ]
}

struct CoveragePolygon {
    let vertices: [SIMD2<Float>]
    let bounds: CoverageBounds

    init(vertices: [SIMD2<Float>]) {
        self.vertices = vertices

        var minX = vertices[0].x
        var maxX = vertices[0].x
        var minY = vertices[0].y
        var maxY = vertices[0].y

        for vertex in vertices.dropFirst() {
            minX = min(minX, vertex.x)
            maxX = max(maxX, vertex.x)
            minY = min(minY, vertex.y)
            maxY = max(maxY, vertex.y)
        }

        bounds = CoverageBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    // Интервал x пересечения выпуклого полигона с горизонтальной полосой.
    // Полигон ∩ полоса - выпуклая область; экстремумы её x достигаются в
    // вершинах полигона внутри полосы либо в точках пересечения рёбер с
    // границами полосы - перебора внутренних точек не требуется.
    func horizontalSlabXRange(slabMinY: Float, slabMaxY: Float) -> ClosedRange<Float>? {
        var lowestX = Float.greatestFiniteMagnitude
        var highestX = -Float.greatestFiniteMagnitude
        var hasIntersection = false

        for index in vertices.indices {
            let start = vertices[index]
            let end = vertices[(index + 1) % vertices.count]

            if start.y >= slabMinY, start.y <= slabMaxY {
                lowestX = min(lowestX, start.x)
                highestX = max(highestX, start.x)
                hasIntersection = true
            }

            let deltaY = end.y - start.y
            guard abs(deltaY) > .ulpOfOne else {
                continue
            }
            let deltaX = end.x - start.x

            let tAtMinY = (slabMinY - start.y) / deltaY
            if tAtMinY >= 0, tAtMinY <= 1 {
                let x = start.x + deltaX * tAtMinY
                lowestX = min(lowestX, x)
                highestX = max(highestX, x)
                hasIntersection = true
            }

            let tAtMaxY = (slabMaxY - start.y) / deltaY
            if tAtMaxY >= 0, tAtMaxY <= 1 {
                let x = start.x + deltaX * tAtMaxY
                lowestX = min(lowestX, x)
                highestX = max(highestX, x)
                hasIntersection = true
            }
        }

        return hasIntersection ? lowestX...highestX : nil
    }
}

struct CoverageBounds {
    let minX: Float
    let maxX: Float
    let minY: Float
    let maxY: Float
}

private struct TileCandidateRange {
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int

    var normalized: TileCandidateRange? {
        guard minX <= maxX, minY <= maxY else {
            return nil
        }
        return self
    }
}

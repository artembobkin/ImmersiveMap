// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class FlatVisibleTileResolverTests: XCTestCase {
    // MARK: - Эквивалентность сканлайна и эталонной пер-тайловой проверки

    /// На случайных позах камеры итоговое покрытие (после препроцессора)
    /// нового сканлайн-резолвера совпадает с эталонным brute-force перебором
    /// полного bbox полигона без клампа по дистанции.
    func testResolveMatchesBruteForceReferenceAcrossRandomPoses() {
        var random = SplitMix64(seed: 0x1AB5_5EED)
        let preprocessor = VisibleTilesPreprocessor()

        for iteration in 0..<40 {
            let targetZoom = Int(random.next(upperBound: 7)) + 1
            let pitch = Float(random.unitDouble()) * 1.31          // 0..75°
            let bearing = Float(random.unitDouble()) * 2 * .pi
            let pan = SIMD2<Double>(random.unitDouble() * 2 - 1,
                                    random.unitDouble() * 2 - 1)
            let distance = 0.4 + random.unitDouble() * 4.0

            let flatRenderState = FlatRenderState(pan: pan, renderMapSize: 8.0)
            let cameraMatrix = Self.makeCameraMatrix(pitch: pitch,
                                                     bearing: bearing,
                                                     distance: Float(distance),
                                                     aspect: 1.86)
            let center = Self.makeCenter(targetZoom: targetZoom, flatRenderState: flatRenderState)

            guard let polygon = FlatVisibleTileResolver.makeCoveragePolygon(cameraMatrix: cameraMatrix) else {
                continue
            }

            let resolved = FlatVisibleTileResolver.resolveVisibleTiles(targetZoom: targetZoom,
                                                                       center: center,
                                                                       flatRenderState: flatRenderState,
                                                                       cameraMatrix: cameraMatrix)
            let reference = Self.bruteForceVisibleTiles(polygon: polygon,
                                                        targetZoom: targetZoom,
                                                        flatRenderState: flatRenderState)

            let resolvedCoverage = Set(preprocessor.preprocess(visibleTiles: Array(resolved),
                                                               center: center,
                                                               renderSurfaceMode: .flat))
            let referenceCoverage = Set(preprocessor.preprocess(visibleTiles: Array(reference),
                                                                center: center,
                                                                renderSurfaceMode: .flat))
            XCTAssertEqual(resolvedCoverage, referenceCoverage,
                           "Расхождение на итерации \(iteration): z\(targetZoom) pitch \(pitch) bearing \(bearing) pan \(pan)")
        }
    }

    /// Сырой выход резолвера в пределах радиуса клампа тоже совпадает
    /// с эталоном (кламп может отбрасывать только тайлы дальше радиуса).
    func testResolveMatchesBruteForceWithinClampRadius() {
        var random = SplitMix64(seed: 0xDEAD_BEEF)
        for _ in 0..<40 {
            let targetZoom = Int(random.next(upperBound: 7)) + 1
            let pitch = Float(random.unitDouble()) * 1.31
            let bearing = Float(random.unitDouble()) * 2 * .pi
            let pan = SIMD2<Double>(random.unitDouble() * 2 - 1,
                                    random.unitDouble() * 2 - 1)
            let flatRenderState = FlatRenderState(pan: pan, renderMapSize: 8.0)
            let cameraMatrix = Self.makeCameraMatrix(pitch: pitch,
                                                     bearing: bearing,
                                                     distance: Float(0.4 + random.unitDouble() * 4.0),
                                                     aspect: 1.86)
            let center = Self.makeCenter(targetZoom: targetZoom, flatRenderState: flatRenderState)

            guard let polygon = FlatVisibleTileResolver.makeCoveragePolygon(cameraMatrix: cameraMatrix) else {
                continue
            }

            let resolved = FlatVisibleTileResolver.resolveVisibleTiles(targetZoom: targetZoom,
                                                                       center: center,
                                                                       flatRenderState: flatRenderState,
                                                                       cameraMatrix: cameraMatrix)
            let reference = Self.bruteForceVisibleTiles(polygon: polygon,
                                                        targetZoom: targetZoom,
                                                        flatRenderState: flatRenderState)
            let radius = VisibleTilesPreprocessor.defaultMaxVisibleRelativeDistance
            let referenceWithinRadius = reference.filter { tile in
                VisibleTileRelativeDistance.compute(tile: tile, center: center, renderSurfaceMode: .flat) <= radius
            }

            XCTAssertEqual(resolved.filter { tile in
                VisibleTileRelativeDistance.compute(tile: tile, center: center, renderSurfaceMode: .flat) <= radius
            }, referenceWithinRadius)
        }
    }

    /// Поза со скриншота бага: z14, pitch 75°, широкий вьюпорт. Раньше bbox
    /// полигона давал миллионы кандидатов и кадр на секунды; теперь выход
    /// ограничен радиусом клампа, а перечисление - сканлайн.
    func testHighPitchPoseStaysBoundedAndFast() {
        let targetZoom = 14
        let flatRenderState = FlatRenderState(pan: SIMD2<Double>(0.083, -0.42),
                                              renderMapSize: 2048.0)
        let cameraMatrix = Self.makeCameraMatrix(pitch: 75 * .pi / 180,
                                                 bearing: 15 * .pi / 180,
                                                 distance: 0.35,
                                                 aspect: 3594.0 / 1930.0)
        let center = Self.makeCenter(targetZoom: targetZoom, flatRenderState: flatRenderState)

        let resolved = FlatVisibleTileResolver.resolveVisibleTiles(targetZoom: targetZoom,
                                                                   center: center,
                                                                   flatRenderState: flatRenderState,
                                                                   cameraMatrix: cameraMatrix)

        let radius = VisibleTilesPreprocessor.defaultMaxVisibleRelativeDistance
        let boundPerLoop = (2 * radius + 1) * (2 * radius + 1)
        XCTAssertFalse(resolved.isEmpty)
        XCTAssertLessThanOrEqual(resolved.count, boundPerLoop * 3)

        measure {
            for _ in 0..<100 {
                _ = FlatVisibleTileResolver.resolveVisibleTiles(targetZoom: targetZoom,
                                                                center: center,
                                                                flatRenderState: flatRenderState,
                                                                cameraMatrix: cameraMatrix)
            }
        }
    }

    // MARK: - Эталонная реализация (пер-тайловые полигон-тесты до оптимизации)

    private static func bruteForceVisibleTiles(polygon: CoveragePolygon,
                                               targetZoom: Int,
                                               flatRenderState: FlatRenderState) -> Set<VisibleTile> {
        let tilesCount = 1 << targetZoom
        let mapSize = flatRenderState.renderMapSize
        let tileSize = mapSize / Double(tilesCount)
        var result: Set<VisibleTile> = []

        for loop in [Int8(-1), 0, 1] {
            let halfMapSize = mapSize * 0.5
            let xOffset = -halfMapSize + flatRenderState.pan.x * halfMapSize + Double(loop) * mapSize
            let yOffset = -halfMapSize - flatRenderState.pan.y * halfMapSize
            let padding = max(tileSize * 1e-6, 1e-6)

            let minColumn = max(0, Int(floor((Double(polygon.bounds.minX) - xOffset - padding) / tileSize)))
            let maxColumn = min(tilesCount - 1, Int(floor((Double(polygon.bounds.maxX) - xOffset + padding) / tileSize)))
            let minRowFromBottom = Int(floor((Double(polygon.bounds.minY) - yOffset - padding) / tileSize))
            let maxRowFromBottom = Int(floor((Double(polygon.bounds.maxY) - yOffset + padding) / tileSize))
            let minY = max(0, (tilesCount - 1) - maxRowFromBottom)
            let maxY = min(tilesCount - 1, (tilesCount - 1) - minRowFromBottom)
            guard minColumn <= maxColumn, minY <= maxY else { continue }

            for y in minY...maxY {
                for x in minColumn...maxColumn {
                    let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: x,
                                                                              y: y,
                                                                              z: targetZoom,
                                                                              loop: loop,
                                                                              flatRenderPan: flatRenderState.pan,
                                                                              renderMapSize: mapSize)
                    let rect = ReferenceRect(minX: origin.x,
                                             maxX: origin.x + origin.z,
                                             minY: origin.y,
                                             maxY: origin.y + origin.z)
                    if Self.polygonIntersectsRect(polygon: polygon, rect: rect) {
                        result.insert(VisibleTile(x: x, y: y, z: targetZoom, loop: loop))
                    }
                }
            }
        }
        return result
    }

    private struct ReferenceRect {
        let minX: Float
        let maxX: Float
        let minY: Float
        let maxY: Float

        var corners: [SIMD2<Float>] {
            [SIMD2(minX, minY), SIMD2(maxX, minY), SIMD2(maxX, maxY), SIMD2(minX, maxY)]
        }

        func contains(point: SIMD2<Float>) -> Bool {
            let tolerance = FlatVisibleTileResolver.planeIntersectionTolerance
            return point.x >= minX - tolerance && point.x <= maxX + tolerance &&
                point.y >= minY - tolerance && point.y <= maxY + tolerance
        }
    }

    private static func polygonIntersectsRect(polygon: CoveragePolygon, rect: ReferenceRect) -> Bool {
        if rect.maxX < polygon.bounds.minX || rect.minX > polygon.bounds.maxX ||
            rect.maxY < polygon.bounds.minY || rect.minY > polygon.bounds.maxY {
            return false
        }
        if polygon.vertices.contains(where: rect.contains(point:)) {
            return true
        }
        if rect.corners.contains(where: { polygonContains(polygon: polygon, point: $0) }) {
            return true
        }
        for index in polygon.vertices.indices {
            let next = (index + 1) % polygon.vertices.count
            if rectIntersectsSegment(rect: rect, from: polygon.vertices[index], to: polygon.vertices[next]) {
                return true
            }
        }
        return false
    }

    private static func polygonContains(polygon: CoveragePolygon, point: SIMD2<Float>) -> Bool {
        let tolerance = FlatVisibleTileResolver.planeIntersectionTolerance
        var hasPositive = false
        var hasNegative = false
        for index in polygon.vertices.indices {
            let next = (index + 1) % polygon.vertices.count
            let edge = polygon.vertices[next] - polygon.vertices[index]
            let relative = point - polygon.vertices[index]
            let cross = edge.x * relative.y - edge.y * relative.x
            if cross > tolerance { hasPositive = true } else if cross < -tolerance { hasNegative = true }
            if hasPositive && hasNegative { return false }
        }
        return true
    }

    private static func rectIntersectsSegment(rect: ReferenceRect,
                                              from start: SIMD2<Float>,
                                              to end: SIMD2<Float>) -> Bool {
        if rect.contains(point: start) || rect.contains(point: end) {
            return true
        }
        let corners = rect.corners
        let edges = [(corners[0], corners[1]), (corners[1], corners[2]),
                     (corners[2], corners[3]), (corners[3], corners[0])]
        for edge in edges {
            if segmentsIntersect(start, end, edge.0, edge.1) {
                return true
            }
        }
        return false
    }

    private static func segmentsIntersect(_ a1: SIMD2<Float>, _ a2: SIMD2<Float>,
                                          _ b1: SIMD2<Float>, _ b2: SIMD2<Float>) -> Bool {
        func orientation(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
            let ab = b - a
            let ac = c - a
            return ab.x * ac.y - ab.y * ac.x
        }
        func onSegment(_ start: SIMD2<Float>, _ end: SIMD2<Float>, _ point: SIMD2<Float>) -> Bool {
            let tolerance = FlatVisibleTileResolver.planeIntersectionTolerance
            return point.x >= min(start.x, end.x) - tolerance && point.x <= max(start.x, end.x) + tolerance &&
                point.y >= min(start.y, end.y) - tolerance && point.y <= max(start.y, end.y) + tolerance
        }
        let tolerance = FlatVisibleTileResolver.planeIntersectionTolerance
        let o1 = orientation(a1, a2, b1)
        let o2 = orientation(a1, a2, b2)
        let o3 = orientation(b1, b2, a1)
        let o4 = orientation(b1, b2, a2)
        if o1 * o2 < 0 && o3 * o4 < 0 { return true }
        if abs(o1) <= tolerance && onSegment(a1, a2, b1) { return true }
        if abs(o2) <= tolerance && onSegment(a1, a2, b2) { return true }
        if abs(o3) <= tolerance && onSegment(b1, b2, a1) { return true }
        if abs(o4) <= tolerance && onSegment(b1, b2, a2) { return true }
        return false
    }

    // MARK: - Построение позы

    /// Перспективная камера, смотрящая на начало render-пространства
    /// (плоскость z=0) с заданным наклоном и азимутом.
    private static func makeCameraMatrix(pitch: Float,
                                         bearing: Float,
                                         distance: Float,
                                         aspect: Float) -> matrix_float4x4 {
        let eye = SIMD3<Float>(sin(bearing) * sin(pitch) * distance,
                               -cos(bearing) * sin(pitch) * distance,
                               cos(pitch) * distance)
        let view = Matrix.lookAt(eye: eye, center: .zero, up: SIMD3<Float>(0, 0, 1))
        let projection = Matrix.perspectiveMatrix(fovRadians: .pi / 3,
                                                  aspect: aspect,
                                                  near: 0.001,
                                                  far: 100)
        return projection * view
    }

    /// Тайловый индекс центра: камера в тестах смотрит на начало
    /// render-пространства, обратное преобразование - как в candidateRange.
    private static func makeCenter(targetZoom: Int, flatRenderState: FlatRenderState) -> Center {
        let tilesCount = 1 << targetZoom
        let mapSize = flatRenderState.renderMapSize
        let tileSize = mapSize / Double(tilesCount)
        let halfMapSize = mapSize * 0.5
        let xOffset = -halfMapSize + flatRenderState.pan.x * halfMapSize
        let yOffset = -halfMapSize - flatRenderState.pan.y * halfMapSize
        let centerTileX = (0 - xOffset) / tileSize
        let rowFromBottom = (0 - yOffset) / tileSize
        let centerTileY = Double(tilesCount) - rowFromBottom
        return Center(tileX: centerTileX, tileY: centerTileY)
    }
}

/// Детерминированный генератор для воспроизводимых property-тестов.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(upperBound: UInt64) -> UInt64 {
        next() % upperBound
    }

    mutating func unitDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

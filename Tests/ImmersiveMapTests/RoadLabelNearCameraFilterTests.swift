// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Фильтр дорожных подписей по видимой экранной площади: квад тайла клипится
/// по near-плоскости и вьюпорту, метрики считаются по видимой части.
/// Вьюпорт в тестах 1000x1000: NDC x/y = -1..1 соответствуют 0..1000 px.
final class RoadLabelNearCameraFilterTests: XCTestCase {
    func testRoadLabelNearCameraFilterDoesNotUsePathOrAnchorCulling() throws {
        let filterSource = try productionSource("ImmersiveMap/Labels/Road/RoadLabelNearCameraFilter.swift")
        let prepareSource = try productionSource("ImmersiveMap/Render/Core/Subsystems/Labels/BaseLabelPrepareSubsystem.swift")

        XCTAssertFalse(filterSource.contains("shouldKeepPath"))
        XCTAssertFalse(filterSource.contains("shouldKeepAnchor"))
        XCTAssertFalse(prepareSource.contains("shouldKeepPath"))
        XCTAssertFalse(prepareSource.contains("shouldKeepAnchor"))
    }

    func testKeepsLargeFullyVisibleTile() {
        // Квад ~700x700 px, без искажений.
        let result = RoadLabelNearCameraFilter.shouldKeepTile(
            clipCorners: quad(minX: 100, minY: 100, maxX: 800, maxY: 800),
            viewportWidth: 1000,
            viewportHeight: 1000
        )

        XCTAssertTrue(result)
    }

    func testRejectsSmallUndistortedTile() {
        // Квадрат 200x200 px меньше порога площади.
        let result = RoadLabelNearCameraFilter.shouldKeepTile(
            clipCorners: quad(minX: 100, minY: 100, maxX: 300, maxY: 300),
            viewportWidth: 1000,
            viewportHeight: 1000
        )

        XCTAssertFalse(result)
    }

    func testRejectsRibbonFailingCompressionRatio() {
        // Диагональная лента ~1300x80 px внутри вьюпорта: площадь 103k
        // проходит, отношение 103k/1300^2 = 0.06 выдаёт сплюснутую
        // перспективой полосу.
        let result = RoadLabelNearCameraFilter.shouldKeepTile(
            clipCorners: [
                clipPoint(x: 60, y: 20, w: 1),
                clipPoint(x: 980, y: 940, w: 1),
                clipPoint(x: 924, y: 996, w: 1),
                clipPoint(x: 4, y: 76, w: 1)
            ],
            viewportWidth: 1000,
            viewportHeight: 1000
        )

        XCTAssertFalse(result)
    }

    func testKeepsNearTileCrossingCameraPlane() {
        // Ближние углы за камерой (w < 0): клип по near-плоскости оставляет
        // видимую половину, и она огромна: тайл сохраняется, вырожденные
        // проекции углов на решение не влияют.
        let corners = [
            clipPoint(x: -400, y: 900, w: 1),
            clipPoint(x: 1400, y: 900, w: 1),
            SIMD4<Float>(0.4, -0.6, 0.0, -0.5),
            SIMD4<Float>(-0.4, -0.6, 0.0, -0.5)
        ]

        let result = RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: corners,
                                                              viewportWidth: 1000,
                                                              viewportHeight: 1000)

        XCTAssertTrue(result)
    }

    func testRejectsTileFullyBehindCamera() {
        let behind = SIMD4<Float>(0.2, 0.2, 0.0, -1.0)
        let result = RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: [behind, behind, behind, behind],
                                                              viewportWidth: 1000,
                                                              viewportHeight: 1000)

        XCTAssertFalse(result)
    }

    func testUnderzoomRequiresMoreVisibleAreaPerContent() {
        // Квад 700x700 (490k px): точному тайлу хватает, а у родителя на два
        // уровня грубее площадь на контент 490k/16 = 30.6k ниже порога 40k:
        // его мир ужат в 16 раз, и подписи вдоль дорог вырождены.
        let corners = quad(minX: 100, minY: 100, maxX: 800, maxY: 800)

        XCTAssertTrue(RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: corners,
                                                               viewportWidth: 1000,
                                                               viewportHeight: 1000,
                                                               underzoomLevels: 0))
        XCTAssertFalse(RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: corners,
                                                                viewportWidth: 1000,
                                                                viewportHeight: 1000,
                                                                underzoomLevels: 2))
    }

    func testNearCoarseParentPassesWithLargeVisibleArea() {
        // Ближний родитель на уровень грубее, накрывающий почти весь экран:
        // видимой площади на контент хватает (900k / 4 > порога).
        let result = RoadLabelNearCameraFilter.shouldKeepTile(
            clipCorners: quad(minX: 20, minY: 20, maxX: 980, maxY: 980),
            viewportWidth: 1000,
            viewportHeight: 1000,
            underzoomLevels: 1
        )

        XCTAssertTrue(result)
    }

    func testVisibleAreaIsClippedByViewport() {
        // Гигантский квад далеко за пределами экрана: решает не полная
        // проекция (17000x200 = 3.4M px), а видимая часть 1000x200 = 200k px.
        // Точному тайлу этого хватает, а родителю на два уровня грубее
        // площади на контент (200k/16 = 12.5k) уже нет: без клипа он прошёл
        // бы (3.4M/16 = 212k).
        let corners = quad(minX: -8000, minY: 400, maxX: 9000, maxY: 600)

        XCTAssertTrue(RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: corners,
                                                               viewportWidth: 1000,
                                                               viewportHeight: 1000,
                                                               underzoomLevels: 0))
        XCTAssertFalse(RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: corners,
                                                                viewportWidth: 1000,
                                                                viewportHeight: 1000,
                                                                underzoomLevels: 2))
    }

    func testTileCornerInputsUseOwnerTileAndSingleSlot() {
        let inputs = RoadLabelNearCameraFilter.makeTileCornerInputs(tile: VisibleTile(x: 12,
                                                                                     y: 34,
                                                                                     z: 6,
                                                                                     loop: -1))

        XCTAssertEqual(inputs.map(\.uv), [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(1, 0),
            SIMD2<Float>(1, 1),
            SIMD2<Float>(0, 1)
        ])
        XCTAssertEqual(inputs.map(\.tile), Array(repeating: SIMD3<Int32>(12, 34, 6), count: 4))
        XCTAssertEqual(inputs.map(\.tileSlotIndex), Array(repeating: UInt32(0), count: 4))
    }

    /// Clip-координата точки с экранной позицией (x, y) px при w = 1
    /// и вьюпорте 1000x1000.
    private func clipPoint(x: Float, y: Float, w: Float) -> SIMD4<Float> {
        let ndcX = x / 1000 * 2 - 1
        let ndcY = y / 1000 * 2 - 1
        return SIMD4<Float>(ndcX * w, ndcY * w, 0, w)
    }

    private func quad(minX: Float, minY: Float, maxX: Float, maxY: Float) -> [SIMD4<Float>] {
        [
            clipPoint(x: minX, y: minY, w: 1),
            clipPoint(x: maxX, y: minY, w: 1),
            clipPoint(x: maxX, y: maxY, w: 1),
            clipPoint(x: minX, y: maxY, w: 1)
        ]
    }

    private func productionSource(_ relativePath: String) throws -> String {
        // cwd на iOS-симуляторе указывает в песочницу; корень пакета выводим из пути этого файла.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

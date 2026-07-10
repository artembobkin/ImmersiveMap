// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class RoadLabelNearCameraFilterTests: XCTestCase {
    func testRoadLabelNearCameraFilterDoesNotUsePathOrAnchorCulling() throws {
        let filterSource = try productionSource("ImmersiveMap/Labels/Road/RoadLabelNearCameraFilter.swift")
        let prepareSource = try productionSource("ImmersiveMap/Render/Core/Subsystems/Labels/BaseLabelPrepareSubsystem.swift")

        XCTAssertFalse(filterSource.contains("shouldKeepPath"))
        XCTAssertFalse(filterSource.contains("shouldKeepAnchor"))
        XCTAssertFalse(prepareSource.contains("shouldKeepPath"))
        XCTAssertFalse(prepareSource.contains("shouldKeepAnchor"))
    }

    func testRejectsTileWithSmallProjectedThickness() {
        let result = RoadLabelNearCameraFilter.shouldKeepTile(cornerPoints: [
            ScreenPointOutput(position: SIMD2<Float>(100, 120), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(2600, 120), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(2600, 128), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(100, 128), depth: 0, visible: 1)
        ],
        viewportWidth: 1000,
        viewportHeight: 1000)

        XCTAssertFalse(result)
    }

    func testRejectsTileWithModeratelyCompressedProjectedThickness() {
        let result = RoadLabelNearCameraFilter.shouldKeepTile(cornerPoints: [
            ScreenPointOutput(position: SIMD2<Float>(100, 120), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(1300, 120), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(1300, 152), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(100, 152), depth: 0, visible: 1)
        ],
        viewportWidth: 1000,
        viewportHeight: 1000)

        XCTAssertFalse(result)
    }

    func testKeepsTileWithEnoughProjectedThickness() {
        let result = RoadLabelNearCameraFilter.shouldKeepTile(cornerPoints: [
            ScreenPointOutput(position: SIMD2<Float>(100, 120), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(500, 140), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(520, 520), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(90, 480), depth: 0, visible: 1)
        ],
        viewportWidth: 1000,
        viewportHeight: 1000)

        XCTAssertTrue(result)
    }

    func testRejectsCompressedTileEvenWhenCornerIsInvisible() {
        let result = RoadLabelNearCameraFilter.shouldKeepTile(cornerPoints: [
            ScreenPointOutput(position: SIMD2<Float>(100, 120), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(2600, 120), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(2600, 128), depth: 0, visible: 0),
            ScreenPointOutput(position: SIMD2<Float>(100, 128), depth: 0, visible: 1)
        ],
        viewportWidth: 1000,
        viewportHeight: 1000)

        XCTAssertFalse(result)
    }

    func testRejectsTileWhenViewportAreaIsInvalid() {
        let result = RoadLabelNearCameraFilter.shouldKeepTile(cornerPoints: [
            ScreenPointOutput(position: SIMD2<Float>(100, 120), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(300, 120), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(300, 125), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(100, 125), depth: 0, visible: 1)
        ],
        viewportWidth: 0,
        viewportHeight: 1000)

        XCTAssertFalse(result)
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

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import XCTest
import simd

/// The frame snapshot picks the model nearest the camera, reports where that
/// model was drawn, and grows only the models too small to aim at.
final class SceneModelSelectionSnapshotTests: XCTestCase {
    private let camera = PickCamera()
    /// 44 pt at a contents scale of 1: the value the selection handler passes.
    private let touchSize: CGFloat = SceneModelSelectionSnapshot.minimumTouchSizePoints
    private let drawnCoordinate = GeoCoordinate(latitude: 48.8584, longitude: 2.2945)

    func testTapOnTheModelReturnsItWithTheCoordinateItWasDrawnAt() {
        let snapshot = makeSnapshot(entries: [unitBoxEntry(id: 7)])

        let hit = snapshot.hitTest(point: camera.center, minimumTouchSizePixels: touchSize)

        XCTAssertEqual(hit?.id, 7)
        XCTAssertEqual(hit?.coordinate.latitude, drawnCoordinate.latitude)
        XCTAssertEqual(hit?.coordinate.longitude, drawnCoordinate.longitude)
    }

    func testTapBesideTheModelHitsNothing() {
        let snapshot = makeSnapshot(entries: [unitBoxEntry(id: 7)])

        XCTAssertNil(snapshot.hitTest(point: CGPoint(x: 10, y: 10),
                                      minimumTouchSizePixels: touchSize))
    }

    func testEmptySnapshotHitsNothing() {
        XCTAssertNil(SceneModelSelectionSnapshot.empty.hitTest(point: camera.center,
                                                               minimumTouchSizePixels: touchSize))
    }

    func testOverlappingModelsResolveToTheNearestOne() {
        let snapshot = makeSnapshot(entries: [
            unitBoxEntry(id: 1, modelMatrix: Matrix.translationMatrix(x: 0, y: 0, z: -5)),
            unitBoxEntry(id: 2)
        ])

        XCTAssertEqual(snapshot.hitTest(point: camera.center, minimumTouchSizePixels: touchSize)?.id, 2)
    }

    func testModelBehindTheCameraHitsNothing() {
        let snapshot = makeSnapshot(entries: [
            unitBoxEntry(id: 1, modelMatrix: Matrix.translationMatrix(x: 0, y: 0, z: 30))
        ])

        XCTAssertNil(snapshot.hitTest(point: camera.center, minimumTouchSizePixels: touchSize))
    }

    // MARK: - Touch target

    /// A model under a pixel across is grown to a touch target, so a tap that
    /// lands near it still selects it.
    func testSubpixelModelGrowsToATouchTarget() throws {
        let snapshot = makeSnapshot(entries: [tinyBoxEntry(id: 3)])
        let projected = try XCTUnwrap(SceneModelPickMath.screenBounds(boundsMin: tinyBoxMin,
                                                                      boundsMax: tinyBoxMax,
                                                                      modelMatrix: matrix_identity_float4x4,
                                                                      projectionView: camera.projectionView,
                                                                      drawSize: camera.drawSize))
        XCTAssertLessThan(projected.width, 2, "The model must be too small to aim at for this test to mean anything")

        let nearMiss = CGPoint(x: camera.center.x + 15, y: camera.center.y)
        XCTAssertEqual(snapshot.hitTest(point: nearMiss, minimumTouchSizePixels: touchSize)?.id, 3)

        let wideMiss = CGPoint(x: camera.center.x + 30, y: camera.center.y)
        XCTAssertNil(snapshot.hitTest(point: wideMiss, minimumTouchSizePixels: touchSize))
    }

    func testTouchTargetIsOffWhenTheMinimumSizeIsZero() {
        let snapshot = makeSnapshot(entries: [tinyBoxEntry(id: 3)])
        let nearMiss = CGPoint(x: camera.center.x + 15, y: camera.center.y)

        XCTAssertNil(snapshot.hitTest(point: nearMiss, minimumTouchSizePixels: 0))
        XCTAssertEqual(snapshot.hitTest(point: camera.center, minimumTouchSizePixels: 0)?.id, 3)
    }

    /// A model large enough to aim at keeps its own outline: a tap outside it
    /// is a background tap, not a near miss.
    func testModelLargerThanTheTouchTargetIsNotGrown() throws {
        let snapshot = makeSnapshot(entries: [unitBoxEntry(id: 7)])
        let projected = try XCTUnwrap(SceneModelPickMath.screenBounds(boundsMin: unitBoxMin,
                                                                      boundsMax: unitBoxMax,
                                                                      modelMatrix: matrix_identity_float4x4,
                                                                      projectionView: camera.projectionView,
                                                                      drawSize: camera.drawSize))
        XCTAssertGreaterThan(projected.width, touchSize)

        let justOutside = CGPoint(x: projected.maxX + 10, y: camera.center.y)
        XCTAssertNil(snapshot.hitTest(point: justOutside, minimumTouchSizePixels: touchSize))
    }

    /// The exact geometry wins over a grown target: a tap inside a big model
    /// does not get stolen by a subpixel one that happens to sit nearby.
    func testGeometryHitWinsOverANearbyTouchTarget() {
        let snapshot = makeSnapshot(entries: [
            unitBoxEntry(id: 7),
            tinyBoxEntry(id: 3, modelMatrix: Matrix.translationMatrix(x: 0.1, y: 0, z: 2))
        ])

        XCTAssertEqual(snapshot.hitTest(point: camera.center, minimumTouchSizePixels: touchSize)?.id, 7)
    }

    // MARK: - Helpers

    private let unitBoxMin = SIMD3<Float>(repeating: -1)
    private let unitBoxMax = SIMD3<Float>(repeating: 1)
    private let tinyBoxMin = SIMD3<Float>(repeating: -0.005)
    private let tinyBoxMax = SIMD3<Float>(repeating: 0.005)

    private func makeSnapshot(entries: [SceneModelSelectionEntry]) -> SceneModelSelectionSnapshot {
        SceneModelSelectionSnapshot(frameIndex: 1,
                                    drawSize: camera.drawSize,
                                    projectionView: camera.projectionView,
                                    cameraEye: camera.eye,
                                    entries: entries)
    }

    private func unitBoxEntry(id: UInt64,
                              modelMatrix: matrix_float4x4 = matrix_identity_float4x4) -> SceneModelSelectionEntry {
        SceneModelSelectionEntry(id: id,
                                 coordinate: drawnCoordinate,
                                 modelMatrix: modelMatrix,
                                 boundsMin: unitBoxMin,
                                 boundsMax: unitBoxMax)
    }

    private func tinyBoxEntry(id: UInt64,
                              modelMatrix: matrix_float4x4 = matrix_identity_float4x4) -> SceneModelSelectionEntry {
        SceneModelSelectionEntry(id: id,
                                 coordinate: drawnCoordinate,
                                 modelMatrix: modelMatrix,
                                 boundsMin: tinyBoxMin,
                                 boundsMax: tinyBoxMax)
    }
}

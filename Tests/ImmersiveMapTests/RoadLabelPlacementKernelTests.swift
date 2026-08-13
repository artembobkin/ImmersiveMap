// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import simd
import XCTest

/// `roadLabelPlacementKernel` consumes already-projected screen points, so the
/// GPU tests feed hand-made projections and read back glyph placements. The
/// regression under test: the label must center on the anchor's own projected
/// point (`pointIndex`), not on the anchor's world `t` lerped along the
/// projected segment. That lerp is not a projection under a tilted perspective
/// camera, and labels on long straight segments slid along the road while
/// tilting.
final class RoadLabelPlacementKernelTests: XCTestCase {
    // MARK: - RoadLabelCache.makeAnchorPointInput (CPU)

    func testAnchorPointInputInterpolatesOnItsSegment() {
        let path = [
            TilePointInput(uv: SIMD2<Float>(0.0, 0.0), tile: SIMD3<Int32>(1, 2, 3)),
            TilePointInput(uv: SIMD2<Float>(0.5, 0.1), tile: SIMD3<Int32>(1, 2, 3)),
            TilePointInput(uv: SIMD2<Float>(0.9, 0.7), tile: SIMD3<Int32>(1, 2, 3))
        ]
        let anchor = RoadLabelAnchor(pathIndex: 0, segmentIndex: 1, t: 0.25, anchorOrdinal: 0)

        let point = RoadLabelCache.makeAnchorPointInput(anchor: anchor, path: path)

        XCTAssertEqual(point.uv.x, 0.6, accuracy: 1e-6)
        XCTAssertEqual(point.uv.y, 0.25, accuracy: 1e-6)
        XCTAssertEqual(point.tile, SIMD3<Int32>(1, 2, 3))
        XCTAssertEqual(point.tileSlotIndex, 0)
    }

    func testAnchorPointInputClampsSegmentIndexAndT() {
        let path = [
            TilePointInput(uv: SIMD2<Float>(0.2, 0.2), tile: SIMD3<Int32>(0, 0, 0)),
            TilePointInput(uv: SIMD2<Float>(0.4, 0.2), tile: SIMD3<Int32>(0, 0, 0))
        ]
        let anchor = RoadLabelAnchor(pathIndex: 0, segmentIndex: 7, t: 1.5, anchorOrdinal: 0)

        let point = RoadLabelCache.makeAnchorPointInput(anchor: anchor, path: path)

        XCTAssertEqual(point.uv.x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(point.uv.y, 0.2, accuracy: 1e-6)
    }

    // MARK: - roadLabelPlacementKernel (GPU)

    func testGlyphCentersOnProjectedAnchorPoint() throws {
        let harness = try Self.makeHarness()
        // Straight horizontal path, 1000 px on screen. The anchor's own
        // projection sits at x=400: under a tilted camera a world-space
        // mid-segment anchor lands off the screen-length midpoint (x=600 for
        // the old t=0.5 lerp), and the label must follow the projection.
        let outputs = try harness.run(
            pathPoints: [
                ScreenPointOutput(position: SIMD2<Float>(100, 300), depth: 0, visible: 1),
                ScreenPointOutput(position: SIMD2<Float>(1100, 300), depth: 0, visible: 1),
                ScreenPointOutput(position: SIMD2<Float>(400, 300), depth: 0, visible: 1)
            ],
            anchors: [RoadLabelAnchorGpu(pathIndex: 0, segmentIndex: 0, pointIndex: 2)],
            glyphInputs: [
                Self.makeGlyphInput(glyphCenter: 50),
                Self.makeGlyphInput(glyphCenter: 10)
            ]
        )

        XCTAssertEqual(outputs[0].visible, 1)
        XCTAssertEqual(outputs[0].extrapolated, 0)
        XCTAssertEqual(outputs[0].position.x, 400, accuracy: 0.01)
        XCTAssertEqual(outputs[0].position.y, 300, accuracy: 0.01)
        XCTAssertEqual(outputs[0].angle, 0, accuracy: 1e-5)
        // The second glyph keeps its pixel offset from the anchored center.
        XCTAssertEqual(outputs[1].visible, 1)
        XCTAssertEqual(outputs[1].position.x, 360, accuracy: 0.01)
    }

    func testInvisibleAnchorPointHidesTheLabel() throws {
        let harness = try Self.makeHarness()
        let outputs = try harness.run(
            pathPoints: [
                ScreenPointOutput(position: SIMD2<Float>(100, 300), depth: 0, visible: 1),
                ScreenPointOutput(position: SIMD2<Float>(1100, 300), depth: 0, visible: 1),
                ScreenPointOutput(position: .zero, depth: 0, visible: 0)
            ],
            anchors: [RoadLabelAnchorGpu(pathIndex: 0, segmentIndex: 0, pointIndex: 2)],
            glyphInputs: [Self.makeGlyphInput(glyphCenter: 50)]
        )

        XCTAssertEqual(outputs[0].visible, 0)
    }

    // MARK: - Harness

    private static func makeGlyphInput(glyphCenter: Float) -> RoadGlyphInput {
        RoadGlyphInput(pathIndex: 0,
                       instanceIndex: 0,
                       labelInstanceIndex: 0,
                       glyphCenter: glyphCenter,
                       labelCenterY: 0,
                       labelWidth: 100,
                       spacing: 0,
                       minLength: 100)
    }

    private static func makeHarness() throws -> Harness {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard let library = try? device.makeDefaultLibrary(bundle: .module) else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Command queue is unavailable")
        }
        let pipeline = RoadLabelPlacementPipeline(metalDevice: device, library: library)
        return Harness(device: device,
                       commandQueue: commandQueue,
                       calculator: RoadLabelPlacementCalculator(pipeline: pipeline))
    }

    private struct Harness {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        let calculator: RoadLabelPlacementCalculator

        func run(pathPoints: [ScreenPointOutput],
                 anchors: [RoadLabelAnchorGpu],
                 glyphInputs: [RoadGlyphInput]) throws -> [RoadGlyphPlacementOutput] {
            let glyphCount = glyphInputs.count
            let collisionInputs = glyphInputs.map { _ in
                ScreenCollisionInput(halfSize: SIMD2<Float>(50, 10), radius: 0, shapeType: .rect)
            }
            let placementsBuffer = try makeBuffer(
                values: [RoadGlyphPlacementOutput](repeating: RoadGlyphPlacementOutput(position: .zero,
                                                                                       angle: 0,
                                                                                       visible: 0,
                                                                                       extrapolated: 0),
                                                  count: glyphCount))
            let dispatch = RoadLabelPlacementCalculator.RecordDispatch(
                pathPointsBuffer: try makeBuffer(values: pathPoints),
                pathRangesBuffer: try makeBuffer(values: [RoadPathRangeGpu(start: 0, count: 2)]),
                anchorsBuffer: try makeBuffer(values: anchors),
                glyphInputsBuffer: try makeBuffer(values: glyphInputs),
                placementsBuffer: placementsBuffer,
                screenPointsBuffer: try makeBuffer(
                    values: [ScreenPointOutput](repeating: ScreenPointOutput(position: .zero,
                                                                             depth: 0,
                                                                             visible: 0),
                                                count: glyphCount)),
                collisionInputsBuffer: try makeBuffer(values: collisionInputs),
                collisionAabbBuffer: try makeBuffer(
                    values: [RoadGlyphCollisionOutput](repeating: RoadGlyphCollisionOutput(halfSizeAABB: .zero),
                                                       count: glyphCount)),
                glyphCount: glyphCount
            )

            let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
            calculator.run(commandBuffer: commandBuffer,
                           screenScale: .identity,
                           dispatches: [dispatch])
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            let pointer = placementsBuffer.contents().bindMemory(to: RoadGlyphPlacementOutput.self,
                                                                 capacity: glyphCount)
            return Array(UnsafeBufferPointer(start: pointer, count: glyphCount))
        }

        private func makeBuffer<T>(values: [T]) throws -> MTLBuffer {
            try XCTUnwrap(values.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!,
                                  length: bytes.count,
                                  options: [.storageModeShared])
            })
        }
    }
}

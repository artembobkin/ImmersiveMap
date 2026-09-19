// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The buildings' screen-footprint level of detail: the radius baked per
/// building and the per-frame uniform the vertex stage sizes it with.
final class BuildingLODTests: XCTestCase {
    func testTheFootprintRadiusHoldsEveryVertexOfTheBuilding() {
        let vertices = [SIMD3<Float>(100, 100, 0), SIMD3<Float>(140, 100, 0),
                        SIMD3<Float>(140, 130, 20), SIMD3<Float>(100, 130, 20)]
            .map { ParsedExtrudedVertex(position: $0, normal: SIMD3<Float>(0, 0, 1), surfaceID: 0) }
        let mesh = ParsedExtrudedMesh(vertices: vertices, indices: [0, 1, 2, 0, 2, 3])
        let radius = TileUnificationStage.footprintRadius(of: mesh)
        XCTAssertEqual(radius, 25, accuracy: 1e-4, "half the diagonal of a 40 by 30 footprint")
        XCTAssertEqual(TileUnificationStage.footprintRadius(of: ParsedExtrudedMesh(vertices: [], indices: [])), 0)
    }

    func testTheVertexCarriesTheRadiusInQuarterUnits() {
        let vertex = ExtrudedVertexIn(position: SIMD3<Float>(1, 2, 3), normal: SIMD3<Float>(0, 0, 1),
                                      styleIndex: 0, footprintRadius: 25.3)
        XCTAssertEqual(vertex.footprintRadius, 101)
        XCTAssertEqual(vertex.footprintRadiusUnits, 25.25)
        XCTAssertEqual(MemoryLayout<ExtrudedVertexIn>.stride, 12, "the radius takes the padding bytes")
        XCTAssertEqual(MemoryLayout<ExtrudedVertexIn>.offset(of: \.footprintRadius), 10)
        XCTAssertEqual(ExtrudedVertexIn(position: .zero, normal: .zero, styleIndex: 0).footprintRadius, 0)
    }

    /// The uniform recovers the projection's focal length from the camera
    /// matrices, and its depth row gives a world point's view depth.
    func testTheUniformSizesAWorldUnitOnScreen() {
        let camera = RenderCamera()
        camera.recalculateProjection(aspect: 1.5)
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5), zoom: 16, bearing: 0, pitch: 0)
        RenderCameraPoseResolver().updateIfNeeded(camera: camera, cameraState: cameraState, transition: 1)
        let projectionView = camera.cameraMatrix!
        let view = camera.view!
        let uniform = BuildingLODUniform.make(projectionView: projectionView,
                                              view: view,
                                              drawableHeightPx: 1000,
                                              cutPixels: 2,
                                              fadePixels: 12)
        let origin = SIMD4<Float>(0, 0, 0, 1)
        let depth = simd_dot(uniform.cameraDepthRow, origin)
        XCTAssertEqual(depth, (projectionView * origin).w, accuracy: 1e-4, "the depth row is the matrix's w row")
        XCTAssertEqual(depth, simd_length(camera.eye), accuracy: 1e-3, "looking at the origin, its depth is the camera distance")
        // A world unit at the look-at point spans this many pixels: the
        // drawable's half height over the visible half height there.
        let visibleHalfHeight = depth * tan(RenderCamera.verticalFovRadians / 2)
        XCTAssertEqual(uniform.pixelsPerWorldUnitAtUnitDepth / depth, 500 / visibleHalfHeight, accuracy: 0.5)
        XCTAssertEqual(uniform.cutPixels, 2)
        XCTAssertEqual(uniform.fadePixels, 12)
        XCTAssertGreaterThan(BuildingLODUniform.make(projectionView: projectionView, view: view,
                                                     drawableHeightPx: 1000, cutPixels: 5, fadePixels: 1).fadePixels, 5,
                             "the fade never sits under the cut")
    }

    func testTheThresholdsAreTheDebugPanels() {
        let controls = DebugOverlayControlState()
        XCTAssertEqual(controls.snapshot().buildingLODCutPixels, BuildingLODUniform.defaultCutPixels)
        XCTAssertEqual(controls.snapshot().buildingLODFadePixels, BuildingLODUniform.defaultFadePixels)
        controls.setBuildingLOD(cutPixels: 3, fadePixels: 20)
        XCTAssertEqual(controls.snapshot().buildingLODCutPixels, 3)
        XCTAssertEqual(controls.snapshot().buildingLODFadePixels, 20)
    }
}

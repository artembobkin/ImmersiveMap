// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// The rules' bands are the whole coverage of the flat map: nothing is
/// placed under them, and no band goes down to the world cover's zoom.
final class TileCullingBackdropTests: XCTestCase {
    func testFlatModeStaysAboveTheFloorZoom() throws {
        let fixture = try makeFixture(zoom: 9.0, renderSurfaceMode: .flat)

        let content = TileCulling().resolveVisibleContent(cameraState: fixture.cameraState,
                                                          resolvedPresentation: fixture.resolvedPresentation,
                                                          targetZoom: 9,
                                                          cameraMatrix: fixture.cameraMatrix,
                                                          cameraFrustum: fixture.cameraFrustum,
                                                          cameraEye: fixture.cameraEye)

        XCTAssertTrue(content.visibleTiles.allSatisfy { $0.z == 9 }, "straight down: the first rule at the target zoom")
        XCTAssertTrue(content.visibleTiles.allSatisfy { $0.z > TileCulling.flatBackdropZoomLevel })
    }

    /// The coverage version is the working set's gate: it moves when the
    /// targets differ from the last frame's, and not when the walk merely
    /// ran again over the same pose.
    func testTheCoverageVersionMovesOnlyWithTheCoverage() throws {
        let culling = TileCulling()
        let fixture = try makeFixture(zoom: 9.0, renderSurfaceMode: .flat)
        func resolve(_ fixture: Fixture, targetZoom: Int) -> VisibleContentState {
            culling.resolveVisibleContent(cameraState: fixture.cameraState,
                                          resolvedPresentation: fixture.resolvedPresentation,
                                          targetZoom: targetZoom,
                                          cameraMatrix: fixture.cameraMatrix,
                                          cameraFrustum: fixture.cameraFrustum,
                                          cameraEye: fixture.cameraEye)
        }
        let first = resolve(fixture, targetZoom: 9)
        let again = resolve(fixture, targetZoom: 9)
        XCTAssertEqual(again.visibleTiles, first.visibleTiles)
        XCTAssertEqual(again.coverageVersion, first.coverageVersion, "the same coverage keeps its version")

        let coarser = resolve(fixture, targetZoom: 8)
        XCTAssertNotEqual(coarser.visibleTiles, first.visibleTiles)
        XCTAssertNotEqual(coarser.coverageVersion, first.coverageVersion, "a different coverage moves it")
    }

    private struct Fixture {
        let cameraState: ImmersiveMapCameraState
        let resolvedPresentation: ResolvedPresentationState
        let cameraMatrix: matrix_float4x4
        let cameraFrustum: Frustum?
        let cameraEye: SIMD3<Float>
    }

    private func makeFixture(zoom: Double,
                             renderSurfaceMode: ViewMode) throws -> Fixture {
        let settings = ImmersiveMapSettings.default
        let center = ImmersiveMapProjection.worldMercator(latitude: 40.7 * Double.pi / 180.0,
                                                          longitude: -74.0 * Double.pi / 180.0)
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: center,
                                                  zoom: zoom,
                                                  bearing: 0,
                                                  pitch: 0)
        let resolver = FrameCameraStateResolver(settings: settings)
        resolver.setCameraState(cameraState)
        let diagnostics = FrameDiagnostics(frameIndex: 0, frameDeltaTime: 0)
        guard let cameraFrameState = resolver.makeFrameState(drawSize: CGSize(width: 1024, height: 768),
                                                             diagnostics: diagnostics) else {
            throw XCTSkip("Camera frame state is required for tile culling fixture.")
        }
        let resolvedPresentation = PresentationStateResolver.resolve(cameraState: cameraFrameState.mapCameraState,
                                                                     settings: settings.presentation,
                                                                     forcedRenderSurfaceMode: renderSurfaceMode)
        return Fixture(cameraState: cameraFrameState.mapCameraState,
                       resolvedPresentation: resolvedPresentation,
                       cameraMatrix: cameraFrameState.cameraMatrices.projectionView,
                       cameraFrustum: cameraFrameState.cameraFrustum,
                       cameraEye: cameraFrameState.cameraEye)
    }
}

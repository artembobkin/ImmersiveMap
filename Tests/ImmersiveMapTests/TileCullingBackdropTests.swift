// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// Подложка горизонта плоского режима: несколько тайлов фиксированного грубого
/// зума закрывают след фрустума без радиусного клампа. На глобусе и при целевом
/// зуме не выше подложечного её нет.
final class TileCullingBackdropTests: XCTestCase {
    func testFlatModeResolvesBackdropTilesAtFixedZoom() throws {
        let fixture = try makeFixture(zoom: 9.0, renderSurfaceMode: .flat)

        let content = TileCulling().resolveVisibleContent(cameraState: fixture.cameraState,
                                                          resolvedPresentation: fixture.resolvedPresentation,
                                                          targetZoom: 9,
                                                          cameraMatrix: fixture.cameraMatrix,
                                                          cameraFrustum: fixture.cameraFrustum,
                                                          cameraEye: fixture.cameraEye)

        XCTAssertFalse(content.backdropTiles.isEmpty)
        XCTAssertTrue(content.backdropTiles.allSatisfy { $0.z == TileCulling.flatBackdropZoomLevel },
                      "Подложка обязана жить на фиксированном зуме, получено: \(content.backdropTiles.map(\.z))")
        XCTAssertTrue(content.visibleTiles.allSatisfy { $0.z == 9 })
    }

    func testGlobeModeHasNoBackdropTiles() throws {
        let fixture = try makeFixture(zoom: 4.0, renderSurfaceMode: .spherical)

        let content = TileCulling().resolveVisibleContent(cameraState: fixture.cameraState,
                                                          resolvedPresentation: fixture.resolvedPresentation,
                                                          targetZoom: 4,
                                                          cameraMatrix: fixture.cameraMatrix,
                                                          cameraFrustum: fixture.cameraFrustum,
                                                          cameraEye: fixture.cameraEye)

        XCTAssertTrue(content.backdropTiles.isEmpty)
    }

    func testBackdropSkippedWhenTargetZoomNotAboveBackdropZoom() throws {
        let fixture = try makeFixture(zoom: 3.0, renderSurfaceMode: .flat)

        let content = TileCulling().resolveVisibleContent(cameraState: fixture.cameraState,
                                                          resolvedPresentation: fixture.resolvedPresentation,
                                                          targetZoom: 3,
                                                          cameraMatrix: fixture.cameraMatrix,
                                                          cameraFrustum: fixture.cameraFrustum,
                                                          cameraEye: fixture.cameraEye)

        XCTAssertTrue(content.backdropTiles.isEmpty)
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
        let diagnostics = FrameDiagnostics(frameIndex: 0, frameTime: 0)
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

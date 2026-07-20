// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
@testable import ImmersiveMap
import simd
import XCTest

final class RenderFrameVisibilityResolverTests: XCTestCase {
    func testGlobeModeResolvesOnlyBaseVisibleTiles() {
        let culling = RecordingTileCulling()
        let resolver = RenderFrameVisibilityResolver(tileCulling: culling)

        let result = resolver.resolve(cameraFrameState: makeCameraFrameState(zoom: 1.74),
                                      resolvedPresentation: makePresentation(renderSurfaceMode: .spherical),
                                      tileSettings: ImmersiveMapSettings.default.tiles)

        XCTAssertEqual(culling.targetZooms, [1])
        XCTAssertEqual(result.tileZoomLevel, 1)
        XCTAssertEqual(result.visibleTiles, [VisibleTile(x: 1, y: 1, z: 1)])
    }

    func testFlatModeResolvesOnlyBaseVisibleTiles() {
        let culling = RecordingTileCulling()
        let resolver = RenderFrameVisibilityResolver(tileCulling: culling)

        let result = resolver.resolve(cameraFrameState: makeCameraFrameState(zoom: 1.74),
                                      resolvedPresentation: makePresentation(renderSurfaceMode: .flat),
                                      tileSettings: ImmersiveMapSettings.default.tiles)

        XCTAssertEqual(culling.targetZooms, [1])
        XCTAssertEqual(result.tileZoomLevel, 1)
        XCTAssertEqual(result.visibleTiles, [VisibleTile(x: 1, y: 1, z: 1)])
    }

    private func makeCameraFrameState(zoom: Double) -> CameraFrameState {
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                  zoom: zoom,
                                                  bearing: 0,
                                                  pitch: 0)
        return CameraFrameState(drawSize: CGSize(width: 512, height: 512),
                                viewport: SIMD2<Float>(512, 512),
                                cameraMatrices: .identity,
                                cameraEye: SIMD3<Float>(0, 0, 1),
                                cameraFrustum: nil,
                                mapCameraState: cameraState,
                                qualityTier: .standard)
    }

    private func makePresentation(renderSurfaceMode: ViewMode) -> ResolvedPresentationState {
        let cameraState = ImmersiveMapCameraState.default
        return ResolvedPresentationState(
            semanticWorldState: SemanticWorldState(cameraState: cameraState),
            presentationState: ImmersiveMapPresentationState(transition: renderSurfaceMode == .spherical ? 0 : 1),
            renderNormalizationState: RenderNormalizationState(zoomScale: 1,
                                                               globeRenderRadius: 1,
                                                               flatRenderMapSize: 1),
            renderSurfaceMode: renderSurfaceMode,
            screenSpaceProjectionMode: renderSurfaceMode == .spherical ? .globe : .flat,
            globeRenderState: GlobeRenderState(pan: SIMD2<Double>(0, 0),
                                               renderRadius: 1,
                                               globeUniform: GlobeUniform(panX: 0,
                                                                          panY: 0,
                                                                          radius: 1,
                                                                          transition: 0)),
            flatRenderState: FlatRenderState(pan: SIMD2<Double>(0, 0),
                                             renderMapSize: 1)
        )
    }
}

private final class RecordingTileCulling: TileCulling {
    private(set) var targetZooms: [Int] = []

    override func resolveVisibleContent(cameraState: ImmersiveMapCameraState,
                                        resolvedPresentation: ResolvedPresentationState,
                                        targetZoom: Int,
                                        cameraMatrix: matrix_float4x4?,
                                        cameraFrustum: Frustum?,
                                        cameraEye: SIMD3<Float>,
                                        diagnostics: (any FrameDiagnosticsService)? = nil) -> VisibleContentState {
        targetZooms.append(targetZoom)
        return VisibleContentState(centerWorldMercator: cameraState.centerWorldMercator,
                                   center: Center(tileX: 0, tileY: 0),
                                   visibleTiles: [VisibleTile(x: targetZoom, y: targetZoom, z: targetZoom)],
                                   backdropTiles: [],
                                   tileZoomLevel: targetZoom,
                                   coverageVersion: UInt64(targetZoom))
    }
}

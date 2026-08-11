// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// The shadow pass needs the off-screen strip of tiles between the frame and
/// the sun: their buildings cast into the frame, and without them shadows pop
/// in and out at the frustum edge while the camera pans. These tests pin the
/// sweep vector, the swept coverage polygon, and the resolved caster strip.
final class ShadowCasterCoverageTests: XCTestCase {
    // MARK: ShadowCasterSweepResolver

    func testSweepIsNilOnGlobeWithShadowsDisabledAndWithLowSun() {
        var scene = ImmersiveMapSettings.default.scene

        XCTAssertNil(ShadowCasterSweepResolver.resolve(renderSurfaceMode: .spherical,
                                                       scene: scene,
                                                       centerWorldMercator: SIMD2(0.5, 0.5),
                                                       renderMapSize: 4096))

        scene.shadows.isEnabled = false
        XCTAssertNil(ShadowCasterSweepResolver.resolve(renderSurfaceMode: .flat,
                                                       scene: scene,
                                                       centerWorldMercator: SIMD2(0.5, 0.5),
                                                       renderMapSize: 4096))

        scene = ImmersiveMapSettings.default.scene
        scene.shadows.strength = 0
        XCTAssertNil(ShadowCasterSweepResolver.resolve(renderSurfaceMode: .flat,
                                                       scene: scene,
                                                       centerWorldMercator: SIMD2(0.5, 0.5),
                                                       renderMapSize: 4096))

        scene = ImmersiveMapSettings.default.scene
        scene.light.direction = SIMD3<Float>(1, 0, 0.01)
        XCTAssertNil(ShadowCasterSweepResolver.resolve(renderSurfaceMode: .flat,
                                                       scene: scene,
                                                       centerWorldMercator: SIMD2(0.5, 0.5),
                                                       renderMapSize: 4096))
    }

    func testSweepFollowsTheSunRayScaledByTheCasterHeightCap() throws {
        // The cap itself is part of the contract: it must track the
        // middle-cascade caster cap, currently 500 meters.
        XCTAssertEqual(ShadowCasterSweepResolver.maxCasterHeightMeters, 500)

        let scene = ImmersiveMapSettings.default.scene
        let centerWorldMercator = SIMD2<Double>(0.5, 0.55)
        let renderMapSize = 65536.0

        let sweep = try XCTUnwrap(ShadowCasterSweepResolver.resolve(renderSurfaceMode: .flat,
                                                                    scene: scene,
                                                                    centerWorldMercator: centerWorldMercator,
                                                                    renderMapSize: renderMapSize))

        // Fixed expectation, computed independently for this fixture: the
        // default light (-0.4, -0.6, 1)/|.| at latitude(-17.711 deg) and map
        // size 65536 gives units-per-meter 0.0017167; 500 m of caster height
        // along the sun ray projects to these ground world units.
        XCTAssertEqual(sweep.x, -0.34334, accuracy: 0.001)
        XCTAssertEqual(sweep.y, -0.51501, accuracy: 0.001)
        let light = simd_normalize(scene.light.direction)
        XCTAssertGreaterThan(simd_dot(sweep, SIMD2<Float>(light.x, light.y)), 0,
                             "The sweep must point sun-ward: casters sit between receivers and the sun")
    }

    // MARK: Swept coverage polygon

    func testSweptCoveragePolygonContainsOriginalAndShiftedVerticesAndStaysConvex() {
        let square = CoveragePolygon(vertices: [
            SIMD2<Float>(0, 0), SIMD2<Float>(4, 0), SIMD2<Float>(4, 4), SIMD2<Float>(0, 4)
        ])
        let offset = SIMD2<Float>(3, 1)

        let swept = FlatVisibleTileResolver.sweptCoveragePolygon(square, offset: offset)

        let expectedInside = square.vertices + square.vertices.map { $0 + offset }
        for point in expectedInside {
            XCTAssertTrue(containsPoint(swept, point: point),
                          "Swept polygon must contain \(point)")
        }
        // Convexity: every vertex triple turns the same way.
        let vertices = swept.vertices
        XCTAssertGreaterThanOrEqual(vertices.count, 4)
        var crossSigns: Set<Bool> = []
        for index in vertices.indices {
            let a = vertices[index]
            let b = vertices[(index + 1) % vertices.count]
            let c = vertices[(index + 2) % vertices.count]
            let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            if abs(cross) > 1e-6 {
                crossSigns.insert(cross > 0)
            }
        }
        XCTAssertEqual(crossSigns.count, 1, "Swept polygon must stay convex")
    }

    // MARK: Caster strip resolution

    func testFlatModeResolvesSunWardCasterStripDisjointFromVisibleTiles() throws {
        let fixture = try makeFixture(zoom: 15.0, renderSurfaceMode: .flat)
        // A multi-tile sweep guarantees a non-empty strip regardless of where
        // the coverage edge falls inside the tile grid (the production sweep is
        // sub-tile, so it only adds tiles where the edge is near a tile border;
        // its magnitude is pinned by the resolver test above).
        let flatRenderState = fixture.resolvedPresentation.flatRenderState
        let tileSizeWorld = Float(flatRenderState.renderMapSize / Double(1 << 15))
        let light = simd_normalize(ImmersiveMapSettings.default.scene.light.direction)
        let sweep = simd_normalize(SIMD2<Float>(light.x, light.y)) * tileSizeWorld * 2.5

        let content = TileCulling().resolveVisibleContent(cameraState: fixture.cameraState,
                                                          resolvedPresentation: fixture.resolvedPresentation,
                                                          targetZoom: 15,
                                                          cameraMatrix: fixture.cameraMatrix,
                                                          cameraFrustum: fixture.cameraFrustum,
                                                          cameraEye: fixture.cameraEye,
                                                          shadowCasterSweep: sweep)

        XCTAssertFalse(content.shadowCasterTiles.isEmpty,
                       "A sun-ward strip of off-screen caster tiles must be resolved")
        XCTAssertTrue(Set(content.shadowCasterTiles).isDisjoint(with: Set(content.visibleTiles)),
                      "The caster strip holds only tiles beyond the visible coverage")
        XCTAssertTrue(content.shadowCasterTiles.allSatisfy { $0.z == 15 })

        // The strip sits sun-ward of the visible coverage: its centroid is
        // displaced from the visible centroid along the sweep.
        let visibleCentroid = centroid(of: content.visibleTiles, flatRenderState: flatRenderState)
        let stripCentroid = centroid(of: content.shadowCasterTiles, flatRenderState: flatRenderState)
        XCTAssertGreaterThan(simd_dot(stripCentroid - visibleCentroid, sweep), 0)

        let resorted = content.shadowCasterTiles.sorted { lhs, rhs in
            if lhs.loop != rhs.loop { return lhs.loop < rhs.loop }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            return lhs.y < rhs.y
        }
        XCTAssertEqual(content.shadowCasterTiles, resorted,
                       "Deterministic order keeps placement hashes stable")
    }

    func testNilSweepResolvesNoCasterStrip() throws {
        let fixture = try makeFixture(zoom: 15.0, renderSurfaceMode: .flat)

        let content = TileCulling().resolveVisibleContent(cameraState: fixture.cameraState,
                                                          resolvedPresentation: fixture.resolvedPresentation,
                                                          targetZoom: 15,
                                                          cameraMatrix: fixture.cameraMatrix,
                                                          cameraFrustum: fixture.cameraFrustum,
                                                          cameraEye: fixture.cameraEye,
                                                          shadowCasterSweep: nil)

        XCTAssertTrue(content.shadowCasterTiles.isEmpty)
    }

    // MARK: Helpers

    private func containsPoint(_ polygon: CoveragePolygon, point: SIMD2<Float>) -> Bool {
        let vertices = polygon.vertices
        var negative = false
        var positive = false
        for index in vertices.indices {
            let a = vertices[index]
            let b = vertices[(index + 1) % vertices.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if cross < -1e-4 { negative = true }
            if cross > 1e-4 { positive = true }
        }
        return !(negative && positive)
    }

    private func centroid(of tiles: [VisibleTile], flatRenderState: FlatRenderState) -> SIMD2<Float> {
        var sum = SIMD2<Double>.zero
        for tile in tiles {
            let tilesCount = 1 << tile.z
            let tileSize = flatRenderState.renderMapSize / Double(tilesCount)
            let halfMapSize = flatRenderState.renderMapSize * 0.5
            let xOffset = -halfMapSize + flatRenderState.pan.x * halfMapSize + Double(tile.loop) * flatRenderState.renderMapSize
            let yOffset = -halfMapSize - flatRenderState.pan.y * halfMapSize
            let rowFromBottom = Double((tilesCount - 1) - tile.y)
            sum.x += xOffset + (Double(tile.x) + 0.5) * tileSize
            sum.y += yOffset + (rowFromBottom + 0.5) * tileSize
        }
        return SIMD2<Float>(Float(sum.x / Double(tiles.count)), Float(sum.y / Double(tiles.count)))
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
                                                  bearing: 0.4,
                                                  pitch: 1.0)
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

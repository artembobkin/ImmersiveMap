// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// End-to-end tests of the avatar pipeline in the order AvatarsRenderer.compute()
/// runs it: presentation store -> projection with culling -> fades -> collision
/// solver. No Metal: the entire CPU chain is verified on thousands of markers.
final class AvatarPipelineIntegrationTests: XCTestCase {
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private static let geometry = AvatarCollisionGeometry(markerSizePx: 128.0,
                                                          bodyRadiusPx: 64.0,
                                                          circleBodyRadiusPx: 59.0,
                                                          bodyCenterOffsetPx: 70.0)

    /// Flat mode: a pile near the center of Moscow is projected and collapses
    /// into flowers; markers scattered across Europe are viewport-culled and
    /// never reach the solver.
    func testFlatPipelineCullsOffscreenAndGroupsPile() throws {
        let store = AvatarPresentationStateStore()
        let image = try Self.makeTestImage()
        var generator = SplitMix(state: 7)

        let centerLatitude = 55.7558
        let centerLongitude = 37.6173
        var markers: [AvatarMarker] = []
        for id in 1...2_000 {
            markers.append(AvatarMarker(id: UInt64(id),
                                        coordinate: GeoCoordinate(latitude: centerLatitude + Double.random(in: -0.02...0.02, using: &generator),
                                                                  longitude: centerLongitude + Double.random(in: -0.02...0.02, using: &generator)),
                                        image: image))
        }
        for id in 2_001...2_500 {
            markers.append(AvatarMarker(id: UInt64(id),
                                        coordinate: GeoCoordinate(latitude: centerLatitude + Double.random(in: -20...20, using: &generator),
                                                                  longitude: centerLongitude + Double.random(in: -20...(-5), using: &generator)),
                                        image: image))
        }
        store.apply(snapshot: AvatarsSnapshot(markers: markers,
                                              removedIds: [],
                                              imageUpdateIds: [],
                                              version: 1),
                    time: 0)

        // Camera: orthographic world-to-clip projection, 800x600 viewport,
        // visible width of 800 world units; pan centers Moscow.
        let renderMapSize = 1_000_000.0
        let moscowXNorm = (centerLongitude * .pi / 180.0 + .pi) / (2.0 * .pi)
        let moscowYNorm = ImmersiveMapProjection.yMercatorNormalized(latitude: centerLatitude * .pi / 180.0)
        let presentation = Self.makeFlatPresentation(pan: SIMD2(1.0 - 2.0 * moscowXNorm, moscowYNorm),
                                                     renderMapSize: renderMapSize)
        let cameraUniform = Self.makeOrthographicCamera(visibleWorldWidth: 800.0,
                                                        visibleWorldHeight: 600.0)
        let drawSize = CGSize(width: 800, height: 600)

        let projector = AvatarSelectionProjector()
        let presented = store.presentedEntries(at: 0)
        XCTAssertEqual(presented.count, 2_500)
        let projected = projector.project(markers: presented,
                                          drawSize: drawSize,
                                          cameraUniform: cameraUniform,
                                          resolvedPresentation: presentation,
                                          cullMarginPx: 476.0)

        // Europe is beyond the cull margin; the pile (±0.02 deg ≈ ±111 world
        // units) is fully on screen.
        XCTAssertEqual(projected.count, 2_000)
        XCTAssertTrue(projected.allSatisfy { $0.marker.id <= 2_000 })
        // Solver input is sorted by id without re-sorting.
        XCTAssertTrue(zip(projected, projected.dropFirst()).allSatisfy { $0.marker.id < $1.marker.id })

        let fadeStore = AvatarVisibilityFadeStateStore()
        let fadeResolution = fadeStore.resolve(projectedMarkers: projected,
                                               time: 0,
                                               fadeInSeconds: 0.15,
                                               fadeOutSeconds: 0.25)
        XCTAssertEqual(fadeResolution.projectedMarkers.count, 2_000)

        var config = ImmersiveMapSettings.default.avatars
        config.smoothing = 0.35
        let solver = AvatarCollisionLayoutSolver()
        var layout = AvatarCollisionLayout.empty
        var time: TimeInterval = 0
        for _ in 0..<90 {
            layout = solver.solve(projectedMarkers: fadeResolution.projectedMarkers,
                                  geometry: Self.geometry,
                                  config: config,
                                  time: time)
            time += 1.0 / 60.0
        }

        // The pile is denser than the grouping threshold: some markers hide in
        // flowers; petals and free circles go to the screen - an order of
        // magnitude fewer than the input.
        XCTAssertGreaterThan(layout.flowerGroups.count, 0)
        XCTAssertGreaterThan(layout.markerItems.count, 0)
        XCTAssertLessThan(layout.markerItems.count, 600)
        let coveredByFlowers = layout.flowerGroups.reduce(0) { $0 + $1.memberIDs.count }
        XCTAssertGreaterThan(coveredByFlowers, 1_000)
    }

    /// Globe: a marker on the far side of the sphere is visibility-culled and
    /// does not reach the solver; the near one stays.
    func testGlobePipelineCullsFarSideMarkers() throws {
        let store = AvatarPresentationStateStore()
        let image = try Self.makeTestImage()
        let markers = [
            AvatarMarker(id: 1,
                         coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                         image: image),
            AvatarMarker(id: 2,
                         coordinate: GeoCoordinate(latitude: 0, longitude: 180),
                         image: image)
        ]
        store.apply(snapshot: AvatarsSnapshot(markers: markers,
                                              removedIds: [],
                                              imageUpdateIds: [],
                                              version: 1),
                    time: 0)

        let presentation = Self.makeGlobePresentation()
        let cameraUniform = CameraUniform(matrix: matrix_identity_float4x4,
                                          eye: SIMD3<Float>(0, 0, 1),
                                          padding: 0)

        let projector = AvatarSelectionProjector()
        let projected = projector.project(markers: store.presentedEntries(at: 0),
                                          drawSize: CGSize(width: 800, height: 600),
                                          cameraUniform: cameraUniform,
                                          resolvedPresentation: presentation,
                                          cullMarginPx: 476.0)

        XCTAssertEqual(projected.map(\.marker.id), [1])
        XCTAssertEqual(projected.first?.screenPoint.visibilityAlpha ?? 0, 1.0, accuracy: 0.001)
    }

    // MARK: - Helpers

    private static func makeFlatPresentation(pan: SIMD2<Double>,
                                             renderMapSize: Double) -> ResolvedPresentationState {
        ResolvedPresentationState(
            semanticWorldState: SemanticWorldState(cameraState: .default),
            presentationState: ImmersiveMapPresentationState(transition: 1),
            renderNormalizationState: RenderNormalizationState(zoomScale: 1,
                                                               globeRenderRadius: 1,
                                                               flatRenderMapSize: renderMapSize),
            renderSurfaceMode: .flat,
            screenSpaceProjectionMode: .flat,
            globeRenderState: GlobeRenderState(pan: SIMD2<Double>(0, 0),
                                               renderRadius: 1,
                                               globeUniform: GlobeUniform(panX: 0,
                                                                          panY: 0,
                                                                          radius: 1,
                                                                          transition: 1)),
            flatRenderState: FlatRenderState(pan: pan,
                                             renderMapSize: renderMapSize)
        )
    }

    private static func makeGlobePresentation() -> ResolvedPresentationState {
        ResolvedPresentationState(
            semanticWorldState: SemanticWorldState(cameraState: .default),
            presentationState: ImmersiveMapPresentationState(transition: 0),
            renderNormalizationState: RenderNormalizationState(zoomScale: 1,
                                                               globeRenderRadius: 1,
                                                               flatRenderMapSize: 1),
            renderSurfaceMode: .spherical,
            screenSpaceProjectionMode: .globe,
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

    /// Orthographic projection: world (x, y) -> clip with no perspective.
    private static func makeOrthographicCamera(visibleWorldWidth: Float,
                                               visibleWorldHeight: Float) -> CameraUniform {
        var matrix = matrix_identity_float4x4
        matrix.columns.0.x = 2.0 / visibleWorldWidth
        matrix.columns.1.y = 2.0 / visibleWorldHeight
        matrix.columns.2.z = 0.0
        return CameraUniform(matrix: matrix,
                             eye: SIMD3<Float>(0, 0, 1),
                             padding: 0)
    }

    private static func makeTestImage() throws -> CGImage {
        let bytesPerRow = 4
        var data = Data(repeating: 0xff, count: bytesPerRow)
        let image = data.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(data: baseAddress,
                                          width: 1,
                                          height: 1,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            return context.makeImage()
        }
        return try XCTUnwrap(image)
    }
}

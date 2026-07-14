// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// Сквозные тесты аватарного пайплайна в том порядке, в котором его гоняет
/// AvatarsRenderer.compute(): стор презентации -> проекция с отсечением ->
/// фейды -> солвер коллизий. Без Metal: проверяется вся CPU-цепочка на
/// тысячах маркеров.
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

    /// Плоский режим: куча у центра Москвы проецируется и сворачивается в
    /// цветки, разброс по Европе отсекается вьюпортом и не доходит до солвера.
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

        // Камера: ортографическая проекция мира в клип, вьюпорт 800x600,
        // видимая ширина 800 мировых единиц; пан центрирует Москву.
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

        // Европа за полем отсечения; куча (±0.02 deg ≈ ±111 мировых единиц)
        // на экране целиком.
        XCTAssertEqual(projected.count, 2_000)
        XCTAssertTrue(projected.allSatisfy { $0.marker.id <= 2_000 })
        // Вход солвера отсортирован по id без пересортировки.
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

        // Куча плотнее порога группировки: часть маркеров скрыта в цветках,
        // на экран идут лепестки и свободные кружки - на порядок меньше входа.
        XCTAssertGreaterThan(layout.flowerGroups.count, 0)
        XCTAssertGreaterThan(layout.markerItems.count, 0)
        XCTAssertLessThan(layout.markerItems.count, 600)
        let coveredByFlowers = layout.flowerGroups.reduce(0) { $0 + $1.memberIDs.count }
        XCTAssertGreaterThan(coveredByFlowers, 1_000)
    }

    /// Глобус: маркер на обратной стороне шара отсекается по видимости и не
    /// попадает в солвер, ближний остаётся.
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

    // MARK: - Хелперы

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

    /// Ортографическая проекция: мир (x, y) -> клип без перспективы.
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

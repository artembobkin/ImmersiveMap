// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class PresentationStateResolverTests: XCTestCase {
    func testAutomaticPresentationUsesSphericalSurfaceAtLowZoom() {
        let resolver = MapPresentationStateController(settings: .default)
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                  zoom: 5.0,
                                                  bearing: 0,
                                                  pitch: 0)

        let resolvedPresentation = resolver.resolve(cameraState: cameraState)

        XCTAssertEqual(resolvedPresentation.renderSurfaceMode, .spherical)
        XCTAssertEqual(resolvedPresentation.screenSpaceProjectionMode, .globe)
        XCTAssertEqual(resolvedPresentation.transition, 0.0)
    }

    func testAutomaticPresentationUsesFlatSurfaceAtHighZoom() {
        let resolver = MapPresentationStateController(settings: .default)
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                  zoom: 7.0,
                                                  bearing: 0,
                                                  pitch: 0)

        let resolvedPresentation = resolver.resolve(cameraState: cameraState)

        XCTAssertEqual(resolvedPresentation.renderSurfaceMode, .flat)
        XCTAssertEqual(resolvedPresentation.screenSpaceProjectionMode, .flat)
        XCTAssertEqual(resolvedPresentation.transition, 1.0)
    }

    /// With the globe off the map is the plane at every zoom: a completed
    /// transition and the flat surface where the default would be a sphere.
    func testGlobeDisabledIsTheFlatSurfaceAtEveryZoom() {
        let resolver = MapPresentationStateController(settings: .default.globe(isEnabled: false))
        for zoom in [0.0, 3.0, 5.9, 7.0] {
            let cameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                      zoom: zoom,
                                                      bearing: 0,
                                                      pitch: 0)
            let resolvedPresentation = resolver.resolve(cameraState: cameraState)
            XCTAssertEqual(resolvedPresentation.renderSurfaceMode, .flat, "at zoom \(zoom)")
            XCTAssertEqual(resolvedPresentation.transition, 1.0, "at zoom \(zoom)")
        }
    }

    /// The debug panel's switch still shows the sphere on a globe-disabled
    /// map, and switching again returns to the plane the setting asks for.
    func testTheDebugSwitchStillForcesTheSphereWithTheGlobeDisabled() {
        let resolver = MapPresentationStateController(settings: .default.globe(isEnabled: false))
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                  zoom: 2.0,
                                                  bearing: 0,
                                                  pitch: 0)
        XCTAssertEqual(resolver.resolve(cameraState: cameraState).renderSurfaceMode, .flat)
        resolver.switchRenderSurfaceMode(cameraState: cameraState)
        XCTAssertEqual(resolver.resolve(cameraState: cameraState).renderSurfaceMode, .spherical)
        resolver.switchRenderSurfaceMode(cameraState: cameraState)
        XCTAssertEqual(resolver.resolve(cameraState: cameraState).renderSurfaceMode, .flat)
    }

    /// Near the pole the transition window is stretched by log2(1/cos(latitude)) levels: at a zoom
    /// where the equator is already flat, high latitudes are still mid-morph.
    func testTransitionWindowIsTheSameAtEveryLatitude() {
        let resolver = MapPresentationStateController(settings: .default)
        let settings = ImmersiveMapSettings.default.presentation
        let polarCenter = ImmersiveMapProjection.worldMercator(latitude: 83.0 * .pi / 180.0,
                                                              longitude: 0)
        let equatorCenter = ImmersiveMapProjection.worldMercator(latitude: 0, longitude: 0)
        // The camera's globe proximity absorbs the Mercator inflation
        // (GlobeCameraProximity), so the window is the settings' span at
        // the pole as at the equator.
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let zoom = settings.automaticTransitionStartZoom + settings.automaticTransitionSpan * fraction
            let polar = resolver.resolve(cameraState: ImmersiveMapCameraState(centerWorldMercator: polarCenter, zoom: zoom, bearing: 0, pitch: 0))
            let equator = resolver.resolve(cameraState: ImmersiveMapCameraState(centerWorldMercator: equatorCenter, zoom: zoom, bearing: 0, pitch: 0))
            XCTAssertEqual(polar.transition, equator.transition, accuracy: 1e-6)
            XCTAssertEqual(Double(polar.transition), fraction, accuracy: 1e-6)
        }
    }

    func testTransitionGrowsMonotonicallyWithZoomNearPole() {
        let resolver = MapPresentationStateController(settings: .default)
        let settings = ImmersiveMapSettings.default.presentation
        let polarCenter = ImmersiveMapProjection.worldMercator(latitude: 83.0 * .pi / 180.0,
                                                              longitude: 0)
        let transitions = [0.1, 0.35, 0.6, 0.85].map { fraction in
            let zoom = settings.automaticTransitionStartZoom + settings.automaticTransitionSpan * fraction
            return resolver.resolve(cameraState: ImmersiveMapCameraState(centerWorldMercator: polarCenter,
                                                                         zoom: zoom,
                                                                         bearing: 0,
                                                                         pitch: 0)).transition
        }

        XCTAssertEqual(transitions, transitions.sorted())
        XCTAssertEqual(Set(transitions).count, transitions.count, "The transition steps must not collapse into each other")
    }

    func testMorphGeometryCompletesBeforeSurfaceSwap() {
        let resolver = MapPresentationStateController(settings: .default)
        let lateMorphState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                     zoom: 6.92,
                                                     bearing: 0,
                                                     pitch: 0)

        let lateMorph = resolver.resolve(cameraState: lateMorphState)

        XCTAssertEqual(lateMorph.renderSurfaceMode, .spherical)
        XCTAssertEqual(lateMorph.transition, 0.92, accuracy: 1e-3)
        XCTAssertEqual(lateMorph.globeRenderState.globeUniform.transition, 1.0)
    }

    func testMorphGeometryRunsSlightlyAheadOfSemanticTransition() {
        let resolver = MapPresentationStateController(settings: .default)
        let midMorphState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                    zoom: 6.45,
                                                    bearing: 0,
                                                    pitch: 0)

        let midMorph = resolver.resolve(cameraState: midMorphState)

        XCTAssertEqual(midMorph.transition, 0.45, accuracy: 1e-3)
        XCTAssertEqual(midMorph.globeRenderState.globeUniform.transition, 0.5, accuracy: 1e-3)
    }

    func testSwitchRenderSurfaceModeTemporarilyForcesOppositeSurfaceAndSecondSwitchReturnsToAutomatic() {
        let resolver = MapPresentationStateController(settings: .default)
        let highZoomCameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                          zoom: 7.0,
                                                          bearing: 0,
                                                          pitch: 0)

        resolver.switchRenderSurfaceMode(cameraState: highZoomCameraState)
        let forcedPresentation = resolver.resolve(cameraState: highZoomCameraState)

        XCTAssertEqual(forcedPresentation.renderSurfaceMode, .spherical)
        XCTAssertEqual(forcedPresentation.transition, 0.0)

        resolver.switchRenderSurfaceMode(cameraState: highZoomCameraState)
        let automaticPresentation = resolver.resolve(cameraState: highZoomCameraState)

        XCTAssertEqual(automaticPresentation.renderSurfaceMode, .flat)
        XCTAssertEqual(automaticPresentation.transition, 1.0)
    }
}

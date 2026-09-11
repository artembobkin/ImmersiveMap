// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A host view's renderer: created at once when the process holds the
/// shared GPU resources for its sample count, otherwise once their
/// background build lands, with the camera position given in between
/// honoured. Sample count 2 is the one no other test builds, so the deferred
/// path can be watched from the start. Requires the compiled Metal library,
/// so it skips under `swift test` and runs in the xcodebuild suites.
final class ImmersiveMapDeferredRendererTests: XCTestCase {
    private let deferredSampleCount = 2

    @MainActor
    func testARendererAppearsAtOnceWhenTheResourcesExist() throws {
        try MetalTestEnvironment.requireDevice()
        // The fixture settings hold the default set before the view is made.
        let view = makeHostView(settings: FixtureTiles.tilelessSettings())
        XCTAssertNotNil(view.rendererForTesting, "With the resources built, the renderer is there before init returns")
    }

    @MainActor
    func testARendererFollowsTheBackgroundBuildAndKeepsTheCameraGivenMeanwhile() async throws {
        try requireADeferredSampleCount()
        SharedRenderResources.dropCachedForTesting(sampleCount: deferredSampleCount)
        var settings = FixtureTiles.tilelessSettings()
        settings.postProcessing.multisampleCount = deferredSampleCount
        let camera = ImmersiveMapCameraController()

        let view = makeHostView(settings: settings)
        view.update(settings: settings,
                    avatarsController: nil,
                    cameraController: camera,
                    selectionController: nil,
                    avatarTapAction: nil,
                    markerContent: nil,
                    cameraPosition: nil)
        XCTAssertNil(view.rendererForTesting, "Without the resources the view does not block on building them")

        let position = ImmersiveMapCameraPosition(latitudeDegrees: 48.8584, longitudeDegrees: 2.2945,
                                                  zoom: 12, bearing: 0.3, pitch: 0.2)
        camera.jump(to: position)

        try await waitForRenderer(of: view)
        XCTAssertTrue(SharedRenderResources.isAvailable(sampleCount: deferredSampleCount))
        let current = try XCTUnwrap(view.cameraRuntime.currentCameraPosition())
        XCTAssertEqual(current.latitudeDegrees, position.latitudeDegrees, accuracy: 1e-6,
                       "A jump made while the renderer was pending is where the renderer starts")
        XCTAssertEqual(current.longitudeDegrees, position.longitudeDegrees, accuracy: 1e-6)
        XCTAssertEqual(current.zoom, position.zoom, accuracy: 1e-6)
    }

    @MainActor
    func testDismantlingWhileTheBuildRunsCreatesNothingLater() async throws {
        try requireADeferredSampleCount()
        SharedRenderResources.dropCachedForTesting(sampleCount: deferredSampleCount)
        var settings = FixtureTiles.tilelessSettings()
        settings.postProcessing.multisampleCount = deferredSampleCount

        var view: ImmersiveMapHostView? = makeHostView(settings: settings)
        weak var runtime = view?.hostRuntimeForTesting
        XCTAssertNil(view?.rendererForTesting)
        view = nil

        await SharedRenderResources.prewarm(sampleCount: deferredSampleCount)
        await Task.yield()
        XCTAssertNil(runtime, "A host runtime dropped while its build ran is not kept alive by the pending creation")
    }

    // MARK: - Support

    /// The deferred path needs a sample count nothing has built yet: on a
    /// GPU that cannot render with 2 samples the request resolves to the
    /// default set, which the fixture settings have already built.
    private func requireADeferredSampleCount() throws {
        let device = try MetalTestEnvironment.requireDevice()
        guard RendererSetup.resolvedRenderSampleCount(requested: deferredSampleCount, metalDevice: device) == deferredSampleCount else {
            throw XCTSkip("This GPU resolves \(deferredSampleCount) samples to a set that is already built")
        }
    }

    @MainActor
    private func makeHostView(settings: ImmersiveMapSettings) -> ImmersiveMapHostView {
        ImmersiveMapHostView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), settings: settings)
    }

    @MainActor
    private func waitForRenderer(of view: ImmersiveMapHostView) async throws {
        let deadline = Date().addingTimeInterval(20)
        while view.rendererForTesting == nil {
            if Date() > deadline {
                XCTFail("The renderer never arrived")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

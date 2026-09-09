// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// MSAA as a setting: the sample count the device can render with, the
/// overlay staying out of a multisampled world pass, and a frame actually
/// rendering at 4x. The render case requires the compiled Metal library, so
/// it skips under `swift test` and runs in the xcodebuild workspace suite.
final class MultisampleRenderTests: XCTestCase {
    func testTheResolvedSampleCountNeverExceedsTheRequest() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        for requested in [0, 1, 2, 3, 4, 5, 8, 16] {
            let resolved = RendererSetup.resolvedRenderSampleCount(requested: requested, metalDevice: device)
            XCTAssertLessThanOrEqual(resolved, max(requested, 1), "requested \(requested)")
            XCTAssertTrue(RendererSetup.supportedRenderSampleCounts.contains(resolved), "requested \(requested)")
            XCTAssertTrue(resolved == 1 || device.supportsTextureSampleCount(resolved), "requested \(requested)")
        }
        XCTAssertEqual(RendererSetup.resolvedRenderSampleCount(requested: 1, metalDevice: device), 1)
    }

    /// The overlay pipelines are single-sample: a multisampled world pass
    /// never takes them, models on screen or not.
    func testAMultisampledWorldPassKeepsTheOverlaySeparate() {
        XCTAssertTrue(RenderPassGraph.mergesOverlayIntoWorld(overlayLayers: [.labels, .avatars], renderSampleCount: 1))
        XCTAssertFalse(RenderPassGraph.mergesOverlayIntoWorld(overlayLayers: [.sceneModelOcclusion, .labels], renderSampleCount: 1))
        XCTAssertFalse(RenderPassGraph.mergesOverlayIntoWorld(overlayLayers: [.labels, .avatars], renderSampleCount: 4))
    }

    /// One shared set per sample count, and the same set for two requests
    /// the device resolves alike.
    @MainActor
    func testSharedResourcesAreCachedPerSampleCount() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              (try? device.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
        let one = SharedRenderResources.shared(sampleCount: 1)
        XCTAssertTrue(one === SharedRenderResources.shared(sampleCount: 1))
        XCTAssertEqual(one.renderSampleCount, 1)
        let four = SharedRenderResources.shared(sampleCount: 4)
        XCTAssertEqual(four.renderSampleCount,
                       RendererSetup.resolvedRenderSampleCount(requested: 4, metalDevice: device))
        XCTAssertTrue(four === SharedRenderResources.shared(sampleCount: 4))
        if four.renderSampleCount > 1 {
            XCTAssertFalse(one === four)
        }
    }

    /// Labels on a 4x frame: the overlay pipelines are single-sample, so
    /// they draw in their own pass over the resolved image, and the label
    /// still reaches the picture.
    @MainActor
    func testLabelsDrawOverAMultisampledFrame() async throws {
        let settings = ImmersiveMapSettings.default.msaa()
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings)
        let camera = ImmersiveMapCameraPosition(latitudeDegrees: 55.75, longitudeDegrees: 37.61, zoom: 14)
        harness.setCameraPosition(camera)
        let bare = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        let tiles = WebMercatorTileScheme.neighbourhoodPyramid(latitude: camera.latitudeDegrees,
                                                               longitude: camera.longitudeDegrees,
                                                               maximumZoom: 14)
        for tile in tiles {
            let point = WebMercatorTileScheme.tileLocalPoint(latitude: camera.latitudeDegrees,
                                                             longitude: camera.longitudeDegrees,
                                                             in: tile)
            let containsCamera = (0..<4096).contains(point.0) && (0..<4096).contains(point.1)
            let peaks = containsCamera
                ? [VectorTileFixture.Feature(id: 1, geometry: .point(point.0, point.1), properties: ["name": "Peak", "rank": "1"])]
                : []
            let data = VectorTileFixture.layerTile(layerName: "mountain_peak", features: peaks)
            let loaded = await harness.tileRenderStore.parseTile(tile: tile, data: data)
            XCTAssertTrue(loaded, "The fixture tile \(tile) must parse")
        }
        let labelled = try await harness.renderUntilSettled(changedFrom: bare,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))
        XCTAssertGreaterThan(harness.engine.currentDiagnostics?.counterValue(.baseLabelCount) ?? 0, 0)
        XCTAssertNotEqual(labelled, bare, "The label must be in the 4x picture")
    }

    /// A 4x frame renders end to end: the multisampled world pass resolves
    /// into the target and the overlay pass draws over it, and the picture
    /// is the same opaque globe the single-sample frame paints.
    @MainActor
    func testAMultisampledFrameRenders() async throws {
        var settings = ImmersiveMapSettings.default.msaa()
        settings.scene.starfield.starCount = 0
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings)
        harness.setZoom(1.0)
        let frame = try await harness.renderFrame()
        XCTAssertEqual(frame.count(where: { $0.alpha != 255 }), 0, "The 4x frame must leave no pixel unpainted")
        let space = settings.scene.space.clearColor
        for corner in frame.corners {
            XCTAssertEqual(Int(corner.blue), Int((space.z * 255).rounded()), accuracy: 2, "Space in the corners")
        }
    }
}

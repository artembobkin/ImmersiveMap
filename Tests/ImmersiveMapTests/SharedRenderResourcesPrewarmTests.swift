// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The shared GPU resources built off the main thread: a prewarm builds
/// the set the synchronous path then finds, concurrent requests share one
/// build, and the public entry point reaches the same cache. Sample count 2
/// is the one no other test uses, so each case can drop it and watch it
/// being built. Requires the compiled Metal library, so it skips under
/// `swift test` and runs in the xcodebuild suites.
final class SharedRenderResourcesPrewarmTests: XCTestCase {
    private let sampleCount = 2

    @MainActor
    func testPrewarmBuildsTheSetTheSynchronousPathThenFinds() async throws {
        try MetalTestEnvironment.requireDevice()
        SharedRenderResources.dropCachedForTesting(sampleCount: sampleCount)
        XCTAssertFalse(SharedRenderResources.isAvailable(sampleCount: sampleCount))

        await SharedRenderResources.prewarm(sampleCount: sampleCount)

        XCTAssertTrue(SharedRenderResources.isAvailable(sampleCount: sampleCount))
        let built = await SharedRenderResources.resources(sampleCount: sampleCount)
        XCTAssertTrue(built === SharedRenderResources.shared(sampleCount: sampleCount),
                      "The prewarmed set is the one every later path hands out")
        XCTAssertEqual(built.renderSampleCount,
                       RendererSetup.resolvedRenderSampleCount(requested: sampleCount, metalDevice: built.device))
    }

    @MainActor
    func testConcurrentRequestsShareOneBuild() async throws {
        try MetalTestEnvironment.requireDevice()
        let sampleCount = sampleCount
        SharedRenderResources.dropCachedForTesting(sampleCount: sampleCount)

        async let first = SharedRenderResources.resources(sampleCount: sampleCount)
        async let second = SharedRenderResources.resources(sampleCount: sampleCount)
        let (a, b) = await (first, second)

        XCTAssertTrue(a === b, "Two requests in flight together wait for the same build")
        XCTAssertTrue(a === SharedRenderResources.shared(sampleCount: sampleCount))
    }

    @MainActor
    func testThePublicPrewarmReachesTheSameCache() async throws {
        try MetalTestEnvironment.requireDevice()
        SharedRenderResources.dropCachedForTesting(sampleCount: sampleCount)
        var settings = ImmersiveMapSettings.default
        settings.postProcessing.multisampleCount = sampleCount

        await ImmersiveMapView.prewarm(settings: settings)

        XCTAssertTrue(SharedRenderResources.isAvailable(sampleCount: sampleCount),
                      "ImmersiveMapView.prewarm builds the set for the settings' sample count")
    }
}

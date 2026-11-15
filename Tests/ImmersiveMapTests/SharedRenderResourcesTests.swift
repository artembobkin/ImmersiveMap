// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore
import XCTest
@testable import ImmersiveMap

/// The point of `SharedRenderResources` is that a second renderer pays nothing
/// for immutable GPU state: these tests pin the object identity of the shared
/// pieces across renderer contexts (requires compiled Metal, so they skip
/// under `swift test` and run fully under xcodebuild).
final class SharedRenderResourcesTests: XCTestCase {
    @MainActor
    func testSharedReturnsTheSameInstance() throws {
        try skipUnlessMetalAvailable()

        XCTAssertTrue(try SharedRenderResources.shared(sampleCount: 1) === SharedRenderResources.shared(sampleCount: 1))
    }

    @MainActor
    func testTwoRendererContextsShareImmutableResources() throws {
        try skipUnlessMetalAvailable()

        let first = try makePersistentContext()
        let second = try makePersistentContext()

        // The heavyweight resources must be the very same objects.
        XCTAssertTrue(first.textRenderer === second.textRenderer,
                      "Text atlases and glyph tables must not be rebuilt per view")
        XCTAssertTrue(first.poiSpriteAtlas === second.poiSpriteAtlas)
        XCTAssertTrue(first.tilePipeline === second.tilePipeline)
        XCTAssertTrue(first.globeVectorSurfacePipeline === second.globeVectorSurfacePipeline)
        XCTAssertTrue(first.extrudedTilePipeline === second.extrudedTilePipeline)
        XCTAssertTrue(first.sceneModelPipeline === second.sceneModelPipeline)
        XCTAssertTrue(first.shadowFallbackTexture === second.shadowFallbackTexture)
        XCTAssertTrue(first.extrudedDepthState === second.extrudedDepthState)
        XCTAssertTrue(first.metalContext.library === second.metalContext.library)

        // Mutable state must stay per view.
        XCTAssertFalse(first.tileRenderStore === second.tileRenderStore)
        XCTAssertFalse(first.baseLabelCache === second.baseLabelCache)
        XCTAssertFalse(first.pinsRenderer === second.pinsRenderer)
        XCTAssertFalse(first.starfieldRenderer === second.starfieldRenderer)
        XCTAssertFalse(first.metalContext.commandQueue === second.metalContext.commandQueue)
    }

    private final class StubPinSource: PinRenderSource {
        var currentPinController: ImmersiveMapPinsController? { nil }
    }

    private final class StubAnnotationSource: AnnotationRenderSource {
        var currentAnnotationProjectionInput: AnnotationProjectionInput { .empty }
    }

    private final class StubSceneModelSource: SceneModelRenderSource {
        var currentSceneModelsController: ImmersiveMapSceneModelsController? { nil }
    }

    @MainActor
    private func makePersistentContext() throws -> RenderPersistentContext {
        // A persistent context owns the tile store, and the tile store builds
        // the transport: with the shipped settings this reaches the hosted
        // tile service before a frame is asked for.
        let settings = FixtureTiles.tilelessSettings()
        return try RenderPersistentContext(layer: CAMetalLayer(),
                                           pinSource: StubPinSource(),
                                           annotationSource: StubAnnotationSource(),
                                           sceneModelSource: StubSceneModelSource(),
                                           layerSource: FixedLayerRenderSource(),
                                           styleRuntime: MapStyleRuntime(settings: settings),
                                           config: settings,
                                           eventSink: VideoExportRenderEventSink(),
                                           tileTraceRecorder: TileTraceRecorder(),
                                           baseLabelTraceRecorder: BaseLabelTraceRecorder())
    }

    private func skipUnlessMetalAvailable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? device.makeDefaultLibrary(bundle: ImmersiveMapResourceBundle.bundle())) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
    }
}

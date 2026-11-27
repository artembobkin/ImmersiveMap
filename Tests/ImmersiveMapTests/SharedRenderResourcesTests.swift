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

        // The renderers read one set, so what it holds is the very same
        // objects for both.
        XCTAssertTrue(first.shared === second.shared)
        XCTAssertTrue(first.shared.get(TextAtlas.self) === second.shared.get(TextAtlas.self),
                      "Text atlases and glyph tables must not be rebuilt per view")
        XCTAssertTrue(first.shared.get(PoiSpriteAtlas.self) === second.shared.get(PoiSpriteAtlas.self))
        XCTAssertTrue(first.shared.get(FlatGroundSharedResources.self).pipeline
                      === second.shared.get(FlatGroundSharedResources.self).pipeline)
        XCTAssertTrue(first.shared.get(GlobeVectorSurfaceSharedResources.self).pipeline
                      === second.shared.get(GlobeVectorSurfaceSharedResources.self).pipeline)
        XCTAssertFalse(first.shared.get(FlatGroundSharedResources.self).pipeline
                       === first.shared.get(GlobeVectorSurfaceSharedResources.self).pipeline,
                       "The plane and the sphere build the tile pipeline each its own way")
        XCTAssertTrue(first.shared.get(ExtrudedTilePipeline.self) === second.shared.get(ExtrudedTilePipeline.self))
        XCTAssertTrue(first.shared.get(SceneModelSharedResources.self).pipeline
                      === second.shared.get(SceneModelSharedResources.self).pipeline)
        XCTAssertTrue(first.shared.get(ShadowSharedResources.self).shadowFallbackTexture
                      === second.shared.get(ShadowSharedResources.self).shadowFallbackTexture)
        XCTAssertTrue(first.shared.get(CommonDepthStates.self).scene === second.shared.get(CommonDepthStates.self).scene)
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

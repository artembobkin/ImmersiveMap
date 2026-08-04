// Copyright (c) 2025-2026 ImmersiveMap contributors.
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

        XCTAssertTrue(SharedRenderResources.shared() === SharedRenderResources.shared())
    }

    @MainActor
    func testTwoRendererContextsShareImmutableResources() throws {
        try skipUnlessMetalAvailable()

        let first = makePersistentContext()
        let second = makePersistentContext()

        // The heavyweight resources must be the very same objects.
        XCTAssertTrue(first.textRenderer === second.textRenderer,
                      "Text atlases and glyph tables must not be rebuilt per view")
        XCTAssertTrue(first.poiSpriteAtlas === second.poiSpriteAtlas)
        XCTAssertTrue(first.tilePipeline === second.tilePipeline)
        XCTAssertTrue(first.globeTileTexturePipeline === second.globeTileTexturePipeline)
        XCTAssertTrue(first.extrudedTilePipeline === second.extrudedTilePipeline)
        XCTAssertTrue(first.sceneModelPipeline === second.sceneModelPipeline)
        XCTAssertTrue(first.tilePointScreenPipelines === second.tilePointScreenPipelines)
        XCTAssertTrue(first.roadLabelPlacementPipeline === second.roadLabelPlacementPipeline)
        XCTAssertTrue(first.shadowFallbackTexture === second.shadowFallbackTexture)
        XCTAssertTrue(first.extrudedDepthState === second.extrudedDepthState)
        XCTAssertTrue(first.mapSurfaceGridBuffers.verticesBuffer === second.mapSurfaceGridBuffers.verticesBuffer)
        XCTAssertTrue(first.metalContext.library === second.metalContext.library)

        // Mutable state must stay per view.
        XCTAssertFalse(first.tileRenderStore === second.tileRenderStore)
        XCTAssertFalse(first.tilesTexture === second.tilesTexture)
        XCTAssertFalse(first.baseLabelCache === second.baseLabelCache)
        XCTAssertFalse(first.avatarsRenderer === second.avatarsRenderer)
        XCTAssertFalse(first.starfieldRenderer === second.starfieldRenderer)
        XCTAssertFalse(first.metalContext.commandQueue === second.metalContext.commandQueue)
    }

    private final class StubAvatarSource: AvatarRenderSource {
        var currentAvatarController: ImmersiveMapAvatarsController? { nil }
    }

    private final class StubMarkerSource: MarkerRenderSource {
        var currentMarkerProjectionInput: MarkerProjectionInput { .empty }
    }

    private final class StubSceneModelSource: SceneModelRenderSource {
        var currentSceneModelsController: ImmersiveMapSceneModelsController? { nil }
    }

    @MainActor
    private func makePersistentContext() -> RenderPersistentContext {
        RenderPersistentContext(layer: CAMetalLayer(),
                                avatarSource: StubAvatarSource(),
                                markerSource: StubMarkerSource(),
                                sceneModelSource: StubSceneModelSource(),
                                providerRuntime: ImmersiveMapProviderRuntimeContext(settings: .default),
                                config: .default,
                                eventSink: VideoExportRenderEventSink(),
                                tileTraceRecorder: TileTraceRecorder(),
                                baseLabelTraceRecorder: BaseLabelTraceRecorder())
    }

    private func skipUnlessMetalAvailable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? device.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
    }
}

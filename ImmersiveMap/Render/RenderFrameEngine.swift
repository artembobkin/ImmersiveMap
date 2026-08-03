// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MetalKit
import QuartzCore

/// Owns the map's Metal frame pipeline: resources, subsystem graph, frame attachments, and the render-loop workflow.
final class RenderFrameEngine {
    // MARK: - Dependencies

    private let persistentContext: RenderPersistentContext
    private let renderCamera: FrameCameraStateResolver
    private let presentationStateResolver: MapPresentationStateController
    private let renderGraph: RenderGraph
    private let eventSink: RenderFrameEventSink
    private let passEncoder: RenderFramePassEncoder
    private let visibilityResolver: RenderFrameVisibilityResolver
    private let debugOverlayControls: DebugOverlayControlState

    // MARK: - Settings State

    private var settings: ImmersiveMapSettings

    // MARK: - Frame State

    private let attachments: FrameAttachmentStore
    private let inFlightFramePool = InFlightFramePool(slotsCount: InFlightFramePool.inFlightFramesCount)
    private let clock: RenderFrameClock
    private var debugHUDSnapshotThrottler = DebugOverlayHUDSnapshotThrottler()

    private(set) var currentDiagnostics: FrameDiagnostics?

    // MARK: - Initialization

    init(layer: CAMetalLayer,
         avatarSource: AvatarRenderSource,
         markerSource: MarkerRenderSource,
         sceneModelSource: SceneModelRenderSource,
         providerRuntime: ImmersiveMapProviderRuntimeContext,
         settings: ImmersiveMapSettings = .default,
         debugOverlayControls: DebugOverlayControlState = DebugOverlayControlState(),
         renderCamera: FrameCameraStateResolver,
         presentationStateResolver: MapPresentationStateController,
         eventSink: RenderFrameEventSink,
         tileTraceRecorder: TileTraceRecorder,
         baseLabelTraceRecorder: BaseLabelTraceRecorder,
         clock: RenderFrameClock = RenderFrameWallClock()) {
        let persistentContext = RenderPersistentContext(layer: layer,
                                                        avatarSource: avatarSource,
                                                        markerSource: markerSource,
                                                        sceneModelSource: sceneModelSource,
                                                        providerRuntime: providerRuntime,
                                                        config: settings,
                                                        eventSink: eventSink,
                                                        tileTraceRecorder: tileTraceRecorder,
                                                        baseLabelTraceRecorder: baseLabelTraceRecorder)
        let attachments = FrameAttachmentStore(metalDevice: persistentContext.metalContext.device,
                                               renderSampleCount: persistentContext.metalContext.renderSampleCount)

        let renderGraph = RenderGraphFactory.makeDefaultGraph(context: persistentContext,
                                                              settings: settings,
                                                              debugOverlayControls: debugOverlayControls,
                                                              postProcessingInputTextureProvider: { [attachments] in
                                                                  attachments.currentPostProcessingInputTexture
                                                              },
                                                              buildingImageTextureProvider: { [attachments] in
                                                                  attachments.currentBuildingImageTexture
                                                              })

        self.settings = settings
        self.debugOverlayControls = debugOverlayControls
        self.clock = clock
        self.persistentContext = persistentContext
        self.renderCamera = renderCamera
        self.presentationStateResolver = presentationStateResolver
        self.attachments = attachments
        self.renderGraph = renderGraph
        self.eventSink = eventSink
        self.passEncoder = RenderFramePassEncoder(attachments: attachments,
                                                  renderGraph: renderGraph)
        self.visibilityResolver = RenderFrameVisibilityResolver()
    }

    // MARK: - Rendering

    @discardableResult
    func render(to layer: CAMetalLayer) -> Bool {
        guard let frameSlotIndex = inFlightFramePool.tryAcquire() else {
            recordSkippedFrame(reason: .inFlightSlotsExhausted)
            return false
        }

        let didSchedule = renderFrame(drawSize: layer.drawableSize,
                                      frameSlotIndex: frameSlotIndex,
                                      acquireTarget: { layer.nextDrawable().map { FrameRenderTarget(drawable: $0) } },
                                      onGPUComplete: nil)
        if didSchedule == false {
            inFlightFramePool.release(slot: frameSlotIndex)
        }
        return didSchedule
    }

    /// Renders one frame into a caller-supplied offscreen texture. Used by the
    /// offline video export; nothing is presented. `onGPUComplete` fires on the
    /// Metal completion thread only when this call returned `true`.
    @discardableResult
    func render(offscreen request: RenderFrameOffscreenRequest) -> Bool {
        guard let frameSlotIndex = inFlightFramePool.tryAcquire() else {
            recordSkippedFrame(reason: .inFlightSlotsExhausted)
            return false
        }

        let didSchedule = renderFrame(drawSize: request.drawSize,
                                      frameSlotIndex: frameSlotIndex,
                                      acquireTarget: { FrameRenderTarget(texture: request.texture) },
                                      onGPUComplete: request.onGPUComplete)
        if didSchedule == false {
            inFlightFramePool.release(slot: frameSlotIndex)
        }
        return didSchedule
    }

    // MARK: - Settings

    func applySettings(_ settings: ImmersiveMapSettings) {
        renderCamera.applyCameraSettings(settings.camera)
        presentationStateResolver.applySettings(settings)
        persistentContext.applySettings(settings)
        self.settings = settings
    }

    // MARK: - Memory

    func handleMemoryWarning() {
        renderGraph.handleMemoryWarning()
        attachments.reset()
    }

    // MARK: - Frame Workflow

    private func renderFrame(drawSize: CGSize,
                             frameSlotIndex: Int,
                             acquireTarget: () -> FrameRenderTarget?,
                             onGPUComplete: (@Sendable (Bool) -> Void)?) -> Bool {
        let collectStart = CACurrentMediaTime()
        guard let frameContext = collectInput(drawSize: drawSize, frameSlotIndex: frameSlotIndex) else {
            return false
        }
        frameContext.diagnostics.recordStage(.collectInput, duration: CACurrentMediaTime() - collectStart)

        RenderFrameStageMeasurer.measure(.updateScene, diagnostics: frameContext.diagnostics) {
            renderGraph.update(frameContext: frameContext)
        }
        publishDisplayedTilesForDebug(frameContext: frameContext)
        RenderFrameStageMeasurer.measure(.prepareGPU, diagnostics: frameContext.diagnostics) {
            prepareGPU(frameContext: frameContext)
        }
        let encodeStart = CACurrentMediaTime()
        let target = passEncoder.encode(frameContext: frameContext,
                                        acquireTarget: acquireTarget,
                                        settings: settings)
        frameContext.diagnostics.recordStage(.encodePasses, duration: CACurrentMediaTime() - encodeStart)

        let presentStart = CACurrentMediaTime()
        let didSchedule = presentFrame(frameContext: frameContext,
                                       target: target,
                                       frameSlotIndex: frameSlotIndex,
                                       onGPUComplete: onGPUComplete)
        frameContext.diagnostics.recordStage(.presentFrame, duration: CACurrentMediaTime() - presentStart)

        let hasActiveLabelFadeAnimations = frameContext.sharedState.baseLabelState.hasActiveFadeAnimations
            || frameContext.sharedState.roadLabelState.hasActiveFadeAnimations
        let hasActiveLabelVisibilityCycle = frameContext.sharedState.baseLabelState.hasActiveVisibilityCycle
        let hasActiveAvatarAnimations = frameContext.sharedState.avatarState.hasActiveAnimations
        let hasActiveSceneModelAnimations = frameContext.sharedState.sceneModelState.hasActiveAnimations
        eventSink.applyActivityState(RenderActivityState(labelFadeRenderingActive: hasActiveLabelFadeAnimations,
                                                         labelVisibilityCycleRenderingActive: hasActiveLabelVisibilityCycle,
                                                         avatarAnimationRenderingActive: hasActiveAvatarAnimations,
                                                         sceneModelAnimationRenderingActive: hasActiveSceneModelAnimations))
        // Synchronously and within the same frame: SwiftUI marker positions must
        // land in the same CA transaction as this frame's present. When didSchedule
        // == false the screen shows the old frame and there is nothing to publish.
        if didSchedule, let markerProjectionSnapshot = frameContext.sharedState.markerState.snapshot {
            eventSink.updateMarkerProjectionSnapshot(markerProjectionSnapshot)
        }
        publishDebugOverlayHUDSnapshot(frameContext: frameContext)

        currentDiagnostics = frameContext.diagnostics
        return didSchedule
    }

    private func collectInput(drawSize: CGSize, frameSlotIndex: Int) -> FrameContext? {
        let frameTick = clock.nextFrameTick()
        let diagnostics = FrameDiagnostics(frameIndex: frameTick.index, frameTime: frameTick.time)
        let services = FrameContextServices(diagnostics: diagnostics, settings: settings, now: clock.currentDate())

        guard let cameraFrameState = renderCamera.makeFrameState(drawSize: drawSize,
                                                                 diagnostics: diagnostics) else {
            currentDiagnostics = diagnostics
            return nil
        }

        guard let commandBuffer = persistentContext.metalContext.makeCommandBuffer() else {
            diagnostics.recordSkipReason(.missingCommandBuffer)
            currentDiagnostics = diagnostics
            return nil
        }

        publishStaticResources(frameIndex: frameTick.index)
        let resolvedPresentation = presentationStateResolver.resolve(cameraState: cameraFrameState.mapCameraState)
        let visibleContent = visibilityResolver.resolve(cameraFrameState: cameraFrameState,
                                                        resolvedPresentation: resolvedPresentation,
                                                        tileSettings: settings.tiles,
                                                        diagnostics: diagnostics)

        return FrameContext(frameIndex: frameTick.index,
                            frameSlotIndex: frameSlotIndex,
                            time: frameTick.time,
                            deltaTime: frameTick.deltaTime,
                            drawSize: cameraFrameState.drawSize,
                            viewport: cameraFrameState.viewport,
                            cameraMatrices: cameraFrameState.cameraMatrices,
                            cameraEye: cameraFrameState.cameraEye,
                            qualityTier: cameraFrameState.qualityTier,
                            commandBuffer: commandBuffer,
                            services: services,
                            mapCameraState: cameraFrameState.mapCameraState,
                            resolvedPresentation: resolvedPresentation,
                            visibleContent: visibleContent,
                            diagnostics: diagnostics)
    }

    private func publishStaticResources(frameIndex: UInt64) {
        let resourceRegistry = renderGraph.resourceRegistry
        resourceRegistry.beginFrame(frameIndex: frameIndex)
        resourceRegistry.setPipeline(persistentContext.polygonPipeline.pipelineState, named: .polygonPipeline)
        resourceRegistry.setPipeline(persistentContext.tilePipeline.pipelineState, named: .tilePipeline)
        resourceRegistry.setPipeline(persistentContext.extrudedTilePipeline.pipelineState, named: .extrudedTilePipeline)
        resourceRegistry.setPipeline(persistentContext.extrudedTilePipeline.compositePipelineState, named: .extrudedTileCompositePipeline)
        resourceRegistry.setPipeline(persistentContext.globePipeline.pipelineState, named: .globePipeline)
        resourceRegistry.setTexture(persistentContext.textRenderer.texture, named: .labelGlyphAtlas)
        resourceRegistry.setTexture(persistentContext.poiSpriteAtlas.texture, named: .poiSpriteAtlas)
    }

    private func prepareGPU(frameContext: FrameContext) {
        renderGraph.prepareGPU(frameContext: frameContext)

        let counts = renderGraph.resourceRegistry.counts
        frameContext.services.diagnostics.setCounter(.resourceBufferCount, value: counts.buffers)
        frameContext.services.diagnostics.setCounter(.resourceTextureCount, value: counts.textures)
        frameContext.services.diagnostics.setCounter(.resourcePipelineCount, value: counts.pipelines)
    }

    private func publishDebugOverlayHUDSnapshot(frameContext: FrameContext) {
        guard debugHUDSnapshotThrottler.shouldBuildSnapshot(isEnabled: settings.debug.enableDebugPanel,
                                                            at: CACurrentMediaTime()) else {
            return
        }

        #if DEBUG
        let diagnosticsOverlay: FrameDiagnostics? = frameContext.diagnostics
        #else
        let diagnosticsOverlay: FrameDiagnostics? = nil
        #endif
        let tileLoadingStatus = persistentContext.tileLoadingStatusReporter?.snapshot()
        if let tileLoadingStatus {
            persistentContext.tileTraceRecorder.record(
                .tileLoadingStatusSnapshot(frameIndex: frameContext.frameIndex,
                                           snapshot: tileLoadingStatus)
            )
        }
        eventSink.updateDebugOverlayHUDSnapshot(
            DebugOverlayHUDSnapshot.make(settings: settings.debug,
                                         frameContext: frameContext,
                                         diagnostics: diagnosticsOverlay,
                                         tileLoadingStatus: tileLoadingStatus)
        )
    }

    private func publishDisplayedTilesForDebug(frameContext: FrameContext) {
        guard let tileLoadingStatusReporter = persistentContext.tileLoadingStatusReporter else {
            return
        }
        // The horizon backdrop is not part of placeTileTrackingState (labels and
        // the projection index never see it), yet it is on screen: without it the
        // HUD looks as if the z3 fallback does not exist at all.
        let backdropPlacements = frameContext.sharedState.tilePlacementState.backdropPlaceTilesContext.tilePlacements
        let displayedTiles = (frameContext.sharedState.placeTileTrackingState.placeTiles + backdropPlacements)
            .map(\.metalTile.tile)
        tileLoadingStatusReporter.recordDisplayedTiles(displayedTiles)
    }

    private func presentFrame(frameContext: FrameContext,
                              target: FrameRenderTarget?,
                              frameSlotIndex: Int,
                              onGPUComplete: (@Sendable (Bool) -> Void)?) -> Bool {
        guard let commandBuffer = frameContext.commandBuffer,
              let target else {
            return false
        }

        let avatarSelectionSnapshot = frameContext.sharedState.avatarState.selectionSnapshot
        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            self?.inFlightFramePool.release(slot: frameSlotIndex)
            self?.eventSink.updateAvatarSelectionSnapshot(avatarSelectionSnapshot)
            onGPUComplete?(completedBuffer.error == nil)
        }
        if let drawable = target.drawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
        renderGraph.frameCommitted()
        return true
    }

    // MARK: - Diagnostics

    private func recordSkippedFrame(reason: RenderSkipReason) {
        let frameTick = clock.nextFrameTick()
        let diagnostics = FrameDiagnostics(frameIndex: frameTick.index, frameTime: frameTick.time)
        diagnostics.recordSkipReason(reason)
        diagnostics.recordStage(.collectInput, duration: 0)
        diagnostics.recordStage(.updateScene, duration: 0)
        diagnostics.recordStage(.prepareGPU, duration: 0)
        diagnostics.recordStage(.encodePasses, duration: 0)
        diagnostics.recordStage(.presentFrame, duration: 0)
        currentDiagnostics = diagnostics
    }
}

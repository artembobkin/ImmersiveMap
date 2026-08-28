// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MetalKit
import os
import QuartzCore

/// Owns the map's Metal frame pipeline: resources, subsystem graph, frame attachments, and the render-loop workflow.
final class RenderFrameEngine {
    // MARK: - Dependencies

    private let persistentContext: RenderPersistentContext

    #if DEBUG
    var persistentContextForTesting: RenderPersistentContext {
        persistentContext
    }

    /// Camera state as the next frame would collect it. Read by
    /// `RenderPresentTimingProbe` so a recorded frame carries the state it was
    /// drawn from, which is what separates "the camera moved backwards" from
    /// "the picture moved backwards".
    var debugCameraSample: (zoom: Double, centerX: Double, centerY: Double) {
        let state = renderCamera.currentCameraState()
        return (state.zoom, state.centerWorldMercator.x, state.centerWorldMercator.y)
    }

    /// Frames the engine refused to render at all, by reason, counted since
    /// launch. Distinct from the skip reasons a rendered frame's diagnostics
    /// carry, which are per-layer ("this layer had nothing to draw") and say
    /// nothing about whether the frame reached the screen.
    private(set) var debugFrameSkipCounts: [String: Int] = [:]
    /// Frames the engine scheduled: the counterpart of the above.
    private(set) var debugScheduledFrameCount = 0
    #endif
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
    /// Cascade shadow maps need layered rendering; where it is missing the
    /// frame is drawn without shadows (see `ShadowCascadeAtlas`).
    private let supportsShadowCascades: Bool

    /// GPU duration of the most recently completed frame, written on the Metal
    /// completion thread and read on the main thread when the next frame's
    /// diagnostics are built.
    private let lastCompletedGPUFrameDuration = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    private(set) var currentDiagnostics: FrameDiagnostics?

    // MARK: - Initialization

    /// `@MainActor`: renderer creation resolves the process-wide
    /// ``SharedRenderResources``, and every production and test creation path
    /// already runs on the main actor.
    @MainActor
    init(layer: CAMetalLayer,
         avatarSource: AvatarRenderSource,
         markerSource: MarkerRenderSource,
         sceneModelSource: SceneModelRenderSource,
         routeSource: RouteRenderSource,
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
                                                        routeSource: routeSource,
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
                                                              },
                                                              shadowMapTextureProvider: { [attachments] in
                                                                  attachments.currentShadowMapTexture
                                                              },
                                                              groundShadowMaskTextureProvider: { [attachments] in
                                                                  attachments.currentGroundShadowMaskTexture
                                                              })

        let supportsShadowCascades = ShadowCascadeAtlas.supportsLayeredRendering(
            device: persistentContext.metalContext.device
        )
        if supportsShadowCascades == false {
            ShadowCascadeAtlas.warnAboutMissingLayeredRenderingOnce()
        }
        self.supportsShadowCascades = supportsShadowCascades
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

    /// Renders one live frame into the drawable the display link delivered
    /// with its update. The drawable arrives pre-acquired and already sized,
    /// so the frame is measured against the texture it actually renders into
    /// and never blocks in `nextDrawable()` mid-encode.
    @discardableResult
    func render(to layer: CAMetalLayer, drawable: any CAMetalDrawable) -> Bool {
        updatePresentationSyncMode(layer: layer)
        guard let frameSlotIndex = inFlightFramePool.tryAcquire() else {
            recordSkippedFrame(reason: .inFlightSlotsExhausted)
            return false
        }

        let didSchedule = renderFrame(drawSize: CGSize(width: drawable.texture.width,
                                                       height: drawable.texture.height),
                                      pixelsPerPoint: layer.contentsScale,
                                      frameSlotIndex: frameSlotIndex,
                                      acquireTarget: { FrameRenderTarget(drawable: drawable) },
                                      onGPUComplete: nil)
        if didSchedule == false {
            inFlightFramePool.release(slot: frameSlotIndex)
            #if DEBUG
            debugFrameSkipCounts["notScheduled", default: 0] += 1
            #endif
        }
        #if DEBUG
        if didSchedule {
            debugScheduledFrameCount += 1
        }
        #endif
        return didSchedule
    }

    /// SwiftUI markers are platform views above the Metal layer: their frames
    /// commit with the main-thread CATransaction, while a free-running drawable
    /// presents on its own once the GPU finishes, typically one vsync apart, so
    /// markers visibly detach from their geo points while the camera moves.
    /// While markers exist, the drawable must present inside the transaction
    /// (see `presentFrame`) so map and markers reach the screen in the same
    /// commit; without markers the cheaper free-running present stays.
    private func updatePresentationSyncMode(layer: CAMetalLayer) {
        let needsTransactionSync = persistentContext.markerSource
            .currentMarkerProjectionInput.entries.isEmpty == false
        if layer.presentsWithTransaction != needsTransactionSync {
            layer.presentsWithTransaction = needsTransactionSync
        }
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
                                      pixelsPerPoint: request.pixelsPerPoint,
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

    // MARK: - Teardown

    /// Called when this engine is being discarded while the process lives on
    /// (renderer recreation, view-reuse pool drop, export teardown): stops the
    /// tile loader and cuts late event deliveries from in-flight GPU frames,
    /// which would otherwise resurrect state a successor has just reset.
    func prepareForDiscard() {
        persistentContext.tileRenderStore.cancelLoading()
        (eventSink as? ImmersiveMapRenderEventSink)?.invalidateDelivery()
    }

    // MARK: - Memory

    func handleMemoryWarning() {
        renderGraph.handleMemoryWarning()
        attachments.reset()
    }

    // MARK: - Frame Workflow

    private func renderFrame(drawSize: CGSize,
                             pixelsPerPoint: CGFloat,
                             frameSlotIndex: Int,
                             acquireTarget: () -> FrameRenderTarget?,
                             onGPUComplete: (@Sendable (Bool) -> Void)?) -> Bool {
        let signposter = MapSignposts.render
        let frameSignpostState = signposter.beginInterval("frame")
        defer { signposter.endInterval("frame", frameSignpostState) }

        let collectSignpostState = signposter.beginInterval("stage", "collectInput")
        let collectStart = CACurrentMediaTime()
        let collectedContext = collectInput(drawSize: drawSize,
                                            pixelsPerPoint: pixelsPerPoint,
                                            frameSlotIndex: frameSlotIndex)
        signposter.endInterval("stage", collectSignpostState)
        guard let frameContext = collectedContext else {
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
        let encodeSignpostState = signposter.beginInterval("stage", "encodePasses")
        let encodeStart = CACurrentMediaTime()
        let target = passEncoder.encode(frameContext: frameContext,
                                        acquireTarget: acquireTarget,
                                        settings: settings)
        frameContext.diagnostics.recordStage(.encodePasses, duration: CACurrentMediaTime() - encodeStart)
        signposter.endInterval("stage", encodeSignpostState)

        let presentSignpostState = signposter.beginInterval("stage", "presentFrame")
        let presentStart = CACurrentMediaTime()
        let didSchedule = presentFrame(frameContext: frameContext,
                                       target: target,
                                       frameSlotIndex: frameSlotIndex,
                                       onGPUComplete: onGPUComplete)
        frameContext.diagnostics.recordStage(.presentFrame, duration: CACurrentMediaTime() - presentStart)
        signposter.endInterval("stage", presentSignpostState)

        let hasActiveLabelFadeAnimations = frameContext.sharedState.baseLabelState.hasActiveFadeAnimations
            || frameContext.sharedState.roadLabelState.hasActiveFadeAnimations
        let hasActiveLabelVisibilityCycle = frameContext.sharedState.baseLabelState.hasActiveVisibilityCycle
        let hasActiveAvatarAnimations = frameContext.sharedState.avatarState.hasActiveAnimations
        let hasActiveSceneModelAnimations = frameContext.sharedState.sceneModelState.hasActiveAnimations
        let hasActiveRouteAnimations = frameContext.sharedState.routeState.hasActiveAnimations
        eventSink.applyActivityState(RenderActivityState(labelFadeRenderingActive: hasActiveLabelFadeAnimations,
                                                         labelVisibilityCycleRenderingActive: hasActiveLabelVisibilityCycle,
                                                         avatarAnimationRenderingActive: hasActiveAvatarAnimations,
                                                         sceneModelAnimationRenderingActive: hasActiveSceneModelAnimations,
                                                         routeAnimationRenderingActive: hasActiveRouteAnimations))
        // Independent of `didSchedule`: the animation advanced in `update`
        // whether or not this frame reached a drawable.
        let pathAnimationResults = frameContext.sharedState.sceneModelState.pathAnimationResults
        if pathAnimationResults.isEmpty == false {
            eventSink.completeSceneModelPathAnimations(pathAnimationResults)
        }
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

    private func collectInput(drawSize: CGSize,
                              pixelsPerPoint: CGFloat,
                              frameSlotIndex: Int) -> FrameContext? {
        let frameTick = clock.nextFrameTick()
        let diagnostics = FrameDiagnostics(frameIndex: frameTick.index, frameDeltaTime: frameTick.deltaTime)
        diagnostics.setMeasurement(.gpuFrameDurationMs,
                                   value: lastCompletedGPUFrameDuration.withLock { $0 } * 1000.0)
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
                                                        sceneSettings: settings.scene,
                                                        diagnostics: diagnostics)
        // Resolved once here, so the pass injection and every receiver bind
        // site take the same answer from `ShadowPassGateResolver`: a device
        // without layered rendering renders the frame without shadows rather
        // than failing validation when the cascade pass is encoded.
        let shadowFrameState = supportsShadowCascades
            ? ShadowFrameStateResolver.resolve(
                renderSurfaceMode: resolvedPresentation.renderSurfaceMode,
                cameraEye: cameraFrameState.cameraEye,
                centerWorldMercator: cameraFrameState.mapCameraState.centerWorldMercator,
                flatRenderPan: resolvedPresentation.flatRenderState.pan,
                renderMapSize: resolvedPresentation.flatRenderState.renderMapSize,
                scene: settings.scene
            )
            : nil

        return FrameContext(frameIndex: frameTick.index,
                            frameSlotIndex: frameSlotIndex,
                            time: frameTick.time,
                            deltaTime: frameTick.deltaTime,
                            drawSize: cameraFrameState.drawSize,
                            pixelsPerPoint: pixelsPerPoint,
                            viewport: cameraFrameState.viewport,
                            cameraMatrices: cameraFrameState.cameraMatrices,
                            cameraEye: cameraFrameState.cameraEye,
                            qualityTier: cameraFrameState.qualityTier,
                            commandBuffer: commandBuffer,
                            services: services,
                            mapCameraState: cameraFrameState.mapCameraState,
                            resolvedPresentation: resolvedPresentation,
                            visibleContent: visibleContent,
                            shadowFrameState: shadowFrameState,
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
        let sceneModelSelectionSnapshot = frameContext.sharedState.sceneModelState.selectionSnapshot
        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            // Read the timestamps before entering the lock: withLock takes a
            // @Sendable closure, and MTLCommandBuffer is not Sendable.
            let gpuFrameDuration = completedBuffer.gpuEndTime - completedBuffer.gpuStartTime
            self?.lastCompletedGPUFrameDuration.withLock { $0 = gpuFrameDuration }
            self?.inFlightFramePool.release(slot: frameSlotIndex)
            self?.eventSink.updateAvatarSelectionSnapshot(avatarSelectionSnapshot)
            self?.eventSink.updateSceneModelSelectionSnapshot(sceneModelSelectionSnapshot)
            onGPUComplete?(completedBuffer.error == nil)
        }
        if let drawable = target.drawable {
            if drawable.layer.presentsWithTransaction {
                // Markers are on screen: commit, wait until the buffer is
                // scheduled, then present, so the drawable rides the current
                // CATransaction together with the marker view frames set right
                // after `presentFrame` (Apple's transaction-synced pattern).
                commandBuffer.commit()
                commandBuffer.waitUntilScheduled()
                drawable.present()
            } else {
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
        } else {
            commandBuffer.commit()
        }
        renderGraph.frameCommitted()
        return true
    }

    // MARK: - Diagnostics

    private func recordSkippedFrame(reason: RenderSkipReason) {
        #if DEBUG
        debugFrameSkipCounts[reason.rawValue, default: 0] += 1
        #endif
        let frameTick = clock.nextFrameTick()
        let diagnostics = FrameDiagnostics(frameIndex: frameTick.index, frameDeltaTime: frameTick.deltaTime)
        diagnostics.recordSkipReason(reason)
        diagnostics.recordStage(.collectInput, duration: 0)
        diagnostics.recordStage(.updateScene, duration: 0)
        diagnostics.recordStage(.prepareGPU, duration: 0)
        diagnostics.recordStage(.encodePasses, duration: 0)
        diagnostics.recordStage(.presentFrame, duration: 0)
        currentDiagnostics = diagnostics
    }
}

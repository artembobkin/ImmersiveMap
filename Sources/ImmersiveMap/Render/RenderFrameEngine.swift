// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MetalKit
import os
import QuartzCore

/// The `Render` folder: the frame engine and nothing feature-specific. It
/// owns the frame loop, the render graph and its passes, the frame context
/// and attachments, the subsystem registry, the shared GPU resources and
/// bootstrap, the shared shader headers, post-processing, the offscreen
/// export path and the debug overlay. Every feature's own drawing (its
/// pipelines, shaders, drawers and subsystem) lives in that feature's
/// folder, next to its model and its math, and reaches the frame only
/// through `RenderSubsystem`. No networking or disk cache policy, no style
/// or label policy, no views, gestures or host-app lifecycle.
///
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
    /// The camera's zoom followed over time (`FrameContext.animatedZoom`),
    /// and the camera jumps it has snapped to.
    private var animatedZoom = AnimatedZoom()
    private var animatedZoomCameraJumpCount = 0
    /// The zoom the relief's collapse reads: the zoom a drag over the
    /// terrain began at while the drag lasts, so the mountains stand
    /// however the arm rides the slopes the drag crosses, then the
    /// camera's zoom, followed over a few frames as `animatedZoom` is, so
    /// the drag's end settles the relief rather than drops it. The appear
    /// fade reads the camera's zoom as it is.

    // MARK: - Frame State

    private let attachments: FrameAttachmentStore
    private let inFlightFramePool = InFlightFramePool(slotsCount: InFlightFramePool.inFlightFramesCount)
    /// Keeps the rendered shadow map alive across frames; see the type.
    private let shadowMapReuse = ShadowMapReuseController()
    private let clock: RenderFrameClock
    /// The loader's status last written to the tile trace: the trace takes
    /// a status once per change, not once per frame.
    private var lastTracedTileLoadingStatus: TileLoadingStatusSnapshot?
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
         styleRuntime: MapStyleRuntime,
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
                                                        styleRuntime: styleRuntime,
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
                                                              shadowMapTextureProvider: { [attachments] in
                                                                  attachments.currentShadowMapTexture
                                                              },
                                                              groundShadowMaskTextureProvider: { [attachments] in
                                                                  attachments.currentGroundShadowMaskTexture
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
        // The HUD reads the loader's state between frames through this; the
        // reporter is held weakly so a discarded engine's reporter answers
        // nothing rather than living on in the sink.
        if let reporter = persistentContext.tileLoadingStatusReporter {
            eventSink.attachTileLoadingStatus(provider: { [weak reporter] in reporter?.snapshot() })
            reporter.onChange = { [weak eventSink] in eventSink?.tileLoadingStatusDidChange() }
        }
        // Over a terrain the camera looks at a point on it
        // (`GroundReliefStore.makeTerrainFollow`).
        if let store = persistentContext.groundReliefStore {
            renderCamera.setTerrainFollow(store.makeTerrainFollow(
                tileSettings: settings.tiles,
                globeRadiusScale: settings.presentation.globeRadiusScale,
                cameraZoom: { [weak renderCamera] in renderCamera?.currentCameraState().zoom ?? 0 }))
        }
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
        eventSink.attachTileLoadingStatus(provider: nil)
        persistentContext.tileLoadingStatusReporter?.onChange = nil
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
        let hasActiveAvatarAnimations = frameContext.sharedState.avatarState.hasActiveAnimations
        let hasActiveSceneModelAnimations = frameContext.sharedState.sceneModelState.hasActiveAnimations
        eventSink.applyActivityState(RenderActivityState(labelFadeRenderingActive: hasActiveLabelFadeAnimations,
                                                         avatarAnimationRenderingActive: hasActiveAvatarAnimations,
                                                         sceneModelAnimationRenderingActive: hasActiveSceneModelAnimations,
                                                         extrusionRiseRenderingActive: frameContext.sharedState.isExtrusionRising,
                                                         animatedZoomRenderingActive: animatedZoom.isSettling
                                                             || (persistentContext.groundReliefStore?.isTransitioning ?? false)))
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
        let services = FrameContextServices(diagnostics: diagnostics,
                                            settings: settings,
                                            baseColors: persistentContext.baseColors,
                                            now: clock.currentDate(),
                                            groundRelief: persistentContext.groundReliefStore)

        // The presentation depends on the semantic camera state alone, and
        // the render camera's pose depends on the presentation's phase (the
        // globe proximity), so the presentation resolves first.
        let resolvedPresentation = presentationStateResolver.resolve(cameraState: renderCamera.currentCameraState())
        guard let cameraFrameState = renderCamera.makeFrameState(drawSize: drawSize,
                                                                 diagnostics: diagnostics,
                                                                 transition: resolvedPresentation.presentationState.transition) else {
            currentDiagnostics = diagnostics
            return nil
        }

        // The animated zoom: the camera's followed over a few frames, or
        // snapped to a camera set outright.
        let cameraJumpCount = renderCamera.cameraJumpCount
        let cameraJumped = cameraJumpCount != animatedZoomCameraJumpCount
        animatedZoomCameraJumpCount = cameraJumpCount
        let animatedZoomValue = animatedZoom.advance(toward: cameraFrameState.mapCameraState.zoom,
                                                     deltaTime: frameTick.deltaTime,
                                                     halfLife: settings.camera.animatedZoomHalfLife,
                                                     snap: cameraJumped)
        // The terrain tiles' edges welded to their neighbours' since the
        // last frame, written before this frame's command buffer, on the
        // same queue (`GroundReliefStore.applyPendingWelds`).
        persistentContext.groundReliefStore?.applyPendingWelds(commandQueue: persistentContext.metalContext.commandQueue)
        guard let commandBuffer = persistentContext.metalContext.makeCommandBuffer() else {
            diagnostics.recordSkipReason(.missingCommandBuffer)
            currentDiagnostics = diagnostics
            return nil
        }

        publishStaticResources(frameIndex: frameTick.index)
        // The ring rules are the debug panel's: an edited rule re-runs
        // the coverage like a camera change would.
        // How far the relief falls and rises about the plane this frame,
        // in world units from the last frame's datum: the coverage reaches
        // the tiles the relief lifts into view (`CoveragePolygonBuilder`).
        var reliefHeights: ClosedRange<Float>?
        // The relief's thresholds read the planning zoom, which a drag
        // over the terrain never moves: through a drag the drawn relief
        // must stand still.
        persistentContext.groundReliefStore?.setFrame(zoom: cameraFrameState.planningZoom,
                                                      deltaTime: frameTick.deltaTime,
                                                      snap: cameraJumped)
        // One rise a metre for every tile this frame, the latitude of the
        // point the camera looks at.
        persistentContext.groundReliefStore?.setWorldScale(centerWorldMercator: cameraFrameState.mapCameraState.centerWorldMercator,
                                                           renderMapSize: resolvedPresentation.flatRenderState.renderMapSize)
        // The slopes are shaded by the scene's light, which the settings
        // change live, and fade with the distance from the eye. The debug
        // panel drags the fade and the amounts over the style's.
        persistentContext.groundReliefStore?.setLight(direction: settings.scene.light.direction,
                                                      cameraEye: cameraFrameState.cameraEye,
                                                      fadeCameraDistances: debugOverlayControls.hillshadeFadeCameraDistances(),
                                                      amounts: debugOverlayControls.hillshadeAmounts())
        // The mountains' shadows, as the settings and the debug panel say.
        persistentContext.groundReliefStore?.setCastsShadows(settings.tiles.groundRelief.castsShadows
            && debugOverlayControls.reliefCastsShadows() != false)
        if let store = persistentContext.groundReliefStore, store.isActive,
           resolvedPresentation.renderSurfaceMode == .flat,
           let range = store.heightRangeMetres {
            // At the strength of a mountain: the most any point rises.
            let unitsPerMetre = store.worldUnitsPerMetre * store.strengthScale
            reliefHeights = ((range.lowerBound - store.datumMetres) * unitsPerMetre)
                ... ((range.upperBound - store.datumMetres) * unitsPerMetre)
        }
        let visibleContent = visibilityResolver.resolve(cameraFrameState: cameraFrameState,
                                                        resolvedPresentation: resolvedPresentation,
                                                        tileSettings: settings.tiles,
                                                        ruleSets: debugOverlayControls.snapshot().ringRuleSets,
                                                        reliefHeights: reliefHeights,
                                                        diagnostics: diagnostics)
        // The relief is drawn from under the point the camera looks at:
        // the terrain there is the frame's datum, so the point lies on the
        // ground at the origin and the pose holds as it is. The clearance
        // over a ridge under the eye is the camera's own business, kept
        // through the zoom (`CameraStateController`), never a lift here.
        // After the coverage, which the camera's own pose decides.
        let cameraMatrices = cameraFrameState.cameraMatrices
        let cameraEye = cameraFrameState.cameraEye
        if let groundReliefStore = persistentContext.groundReliefStore {
            if resolvedPresentation.renderSurfaceMode == .flat {
                groundReliefStore.setActive(visibleContent.tileZoomLevel >= groundReliefStore.fromTileZoom
                                            && groundReliefStore.isVisible(atZoom: cameraFrameState.planningZoom))
                if let datum = GroundReliefCameraLift.datumMetres(store: groundReliefStore,
                                                                  centerWorldMercator: cameraFrameState.mapCameraState.centerWorldMercator,
                                                                  tileZoom: visibleContent.tileZoomLevel) {
                    groundReliefStore.setDatum(metres: datum)
                }
            } else {
                groundReliefStore.setActive(false)
                groundReliefStore.setDatum(metres: 0)
            }
        }
        // Resolved once here, so the pass injection and every receiver bind
        // site take the same answer from `ShadowPassGateResolver`.
        let shadowFrameState = shadowMapReuse.resolveFrameState(
            renderSurfaceMode: resolvedPresentation.renderSurfaceMode,
            projectionView: cameraMatrices.projectionView,
            cameraEye: cameraEye,
            centerWorldMercator: cameraFrameState.mapCameraState.centerWorldMercator,
            flatRenderPan: resolvedPresentation.flatRenderState.pan,
            renderMapSize: resolvedPresentation.flatRenderState.renderMapSize,
            // The relief's heights as the coverage reads them: the window
            // reaches the valleys and the summits.
            groundHeights: reliefHeights,
            // The shadows come in with the zoom the eye sees, as the air does.
            zoom: animatedZoomValue,
            scene: settings.scene
        )

        return FrameContext(frameIndex: frameTick.index,
                            frameSlotIndex: frameSlotIndex,
                            time: frameTick.time,
                            deltaTime: frameTick.deltaTime,
                            drawSize: cameraFrameState.drawSize,
                            pixelsPerPoint: pixelsPerPoint,
                            viewport: cameraFrameState.viewport,
                            cameraMatrices: cameraMatrices,
                            cameraEye: cameraEye,
                            commandBuffer: commandBuffer,
                            services: services,
                            mapCameraState: cameraFrameState.mapCameraState,
                            animatedZoom: animatedZoomValue,
                            planningZoom: cameraFrameState.planningZoom,
                            terrainFollowReport: renderCamera.lastTerrainFollowReport,
                            resolvedPresentation: resolvedPresentation,
                            visibleContent: visibleContent,
                            shadowFrameState: shadowFrameState,
                            shadowMapReuse: shadowMapReuse,
                            diagnostics: diagnostics)
    }

    private func publishStaticResources(frameIndex: UInt64) {
        let resourceRegistry = renderGraph.resourceRegistry
        resourceRegistry.beginFrame(frameIndex: frameIndex)
        resourceRegistry.setPipeline(persistentContext.polygonPipeline.pipelineState, named: .polygonPipeline)
        resourceRegistry.setPipeline(persistentContext.tilePipeline.pipelineState, named: .tilePipeline)
        resourceRegistry.setPipeline(persistentContext.extrudedTilePipeline.pipelineState, named: .extrudedTilePipeline)
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

    /// Every rendered frame, for the content the panel shows: the panel is
    /// in step with the frame, one to one, and the frame pays for one
    /// tab's data.
    private func publishDebugOverlayHUDSnapshot(frameContext: FrameContext) {
        // A panel hidden with the map's controls reads nothing.
        guard settings.debug.enableDebugPanel, settings.controls.isHidden == false else {
            return
        }
        let content = eventSink.debugOverlayHUDContentRequest()
        #if DEBUG
        let diagnosticsOverlay: FrameDiagnostics? = content.contains(.stats) ? frameContext.diagnostics : nil
        #else
        let diagnosticsOverlay: FrameDiagnostics? = nil
        #endif
        let tileLoadingStatus = content.contains(.tiles) ? persistentContext.tileLoadingStatusReporter?.snapshot() : nil
        if let tileLoadingStatus, tileLoadingStatus != lastTracedTileLoadingStatus {
            lastTracedTileLoadingStatus = tileLoadingStatus
            persistentContext.tileTraceRecorder.record(
                .tileLoadingStatusSnapshot(frameIndex: frameContext.frameIndex,
                                           snapshot: tileLoadingStatus)
            )
        }
        eventSink.updateDebugOverlayHUDSnapshot(
            DebugOverlayHUDSnapshot.make(settings: settings.debug,
                                         frameContext: frameContext,
                                         diagnostics: diagnosticsOverlay,
                                         tileLoadingStatus: tileLoadingStatus,
                                         content: content)
        )
    }

    private func publishDisplayedTilesForDebug(frameContext: FrameContext) {
        guard let tileLoadingStatusReporter = persistentContext.tileLoadingStatusReporter else {
            return
        }
        let displayedTiles = frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements
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

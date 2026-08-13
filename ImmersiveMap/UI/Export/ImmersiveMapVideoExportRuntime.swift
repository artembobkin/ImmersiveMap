// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Metal
import QuartzCore

/// Owns one offline tour export: builds a headless render stack (its own
/// engine, camera resolver, presentation controller, and scripted clock,
/// independent of the on-screen map) and drives the frame loop, advance the
/// tour timeline, render into a writer-vended pixel buffer, wait for tiles,
/// append. Lives for exactly one export and is released afterwards, freeing
/// the engine's GPU resources and caches.
@MainActor
final class ImmersiveMapVideoExportRuntime {
    private final class VideoExportAvatarSource: AvatarRenderSource {
        private let controller: ImmersiveMapAvatarsController?

        init(controller: ImmersiveMapAvatarsController?) {
            self.controller = controller
        }

        var currentAvatarController: ImmersiveMapAvatarsController? {
            controller
        }
    }

    /// Scene models are excluded from video export in v1: their meshes load
    /// asynchronously in the export engine, which would pop them in mid-video.
    private final class VideoExportSceneModelSource: SceneModelRenderSource {
        var currentSceneModelsController: ImmersiveMapSceneModelsController? {
            nil
        }
    }

    /// Routes are excluded from video export in v1, together with the scene
    /// models they are usually paired with.
    private final class VideoExportRouteSource: RouteRenderSource {
        var currentRoutesController: ImmersiveMapRoutesController? {
            nil
        }
    }

    /// SwiftUI marker views are platform overlays above the Metal layer and
    /// never draw in Metal. The engine still projects their coordinates every
    /// frame from this input, and the export compositor draws the rasterized
    /// views onto finished frames at the projected positions.
    private final class VideoExportMarkerSource: MarkerRenderSource {
        let currentMarkerProjectionInput: MarkerProjectionInput

        init(input: MarkerProjectionInput) {
            self.currentMarkerProjectionInput = input
        }
    }

    private let configuration: ImmersiveMapVideoExportConfiguration
    private let settings: ImmersiveMapSettings
    private let initialPosition: ImmersiveMapCameraPosition
    private let drawSize: CGSize
    private var exportPixelsPerPoint: CGFloat {
        ExportScreenScaleMath.pixelsPerPoint(forOutputSize: drawSize)
    }

    private let writer: VideoExportAssetWriter
    private let clock: RenderFrameScriptedClock
    private let eventSink: VideoExportRenderEventSink
    private let renderCamera: FrameCameraStateResolver
    private let presentationStateResolver: MapPresentationStateController
    private let avatarSource: VideoExportAvatarSource
    private let markerSource: VideoExportMarkerSource
    private let markerOverlay: VideoExportMarkerOverlay?
    private let metalLayer: CAMetalLayer
    private let engine: RenderFrameEngine
    private let textureCache: VideoExportPixelBufferTextureCache
    private var cancelRequested = false
    private var sceneTime: TimeInterval = 0

    private var frameStepSeconds: TimeInterval {
        1 / Double(configuration.framesPerSecond)
    }

    init(settings: ImmersiveMapSettings,
         initialPosition: ImmersiveMapCameraPosition?,
         avatarsController: ImmersiveMapAvatarsController?,
         markerContent: MarkerViewContent?,
         configuration: ImmersiveMapVideoExportConfiguration,
         outputURL: URL) throws {
        self.configuration = configuration
        self.settings = settings
        let drawSize = CGSize(width: configuration.width, height: configuration.height)
        self.drawSize = drawSize
        self.writer = try VideoExportAssetWriter(url: outputURL, configuration: configuration)
        // Local rather than the computed property: the markers rasterize here,
        // before the rest of `self` exists.
        let markerScale = ExportScreenScaleMath.markerRasterizationScale(markerScale: configuration.markerScale,
                                                                         outputSize: drawSize)
        self.markerOverlay = markerContent.flatMap {
            VideoExportMarkerOverlay(content: $0, scale: markerScale)
        }

        let clock = RenderFrameScriptedClock(date: configuration.sceneDate ?? Date())
        self.clock = clock
        let eventSink = VideoExportRenderEventSink()
        self.eventSink = eventSink
        let renderCamera = FrameCameraStateResolver(settings: settings)
        self.renderCamera = renderCamera
        // The fallback mirrors the on-screen map before any position was set:
        // the resolver's built-in default.
        self.initialPosition = initialPosition ?? renderCamera.currentCameraPosition()
        let presentationStateResolver = MapPresentationStateController(settings: settings)
        self.presentationStateResolver = presentationStateResolver
        let avatarSource = VideoExportAvatarSource(controller: avatarsController)
        self.avatarSource = avatarSource
        let markerSource = VideoExportMarkerSource(input: markerOverlay?.projectionInput ?? .empty)
        self.markerSource = markerSource

        // Device and pixel-format carrier only: the offscreen path never asks
        // this layer for a drawable.
        let metalLayer = CAMetalLayer()
        self.metalLayer = metalLayer
        self.engine = RenderFrameEngine(layer: metalLayer,
                                        avatarSource: avatarSource,
                                        markerSource: markerSource,
                                        sceneModelSource: VideoExportSceneModelSource(),
                                        routeSource: VideoExportRouteSource(),
                                        providerRuntime: ImmersiveMapProviderRuntimeContext(settings: settings),
                                        settings: settings,
                                        debugOverlayControls: DebugOverlayControlState(),
                                        renderCamera: renderCamera,
                                        presentationStateResolver: presentationStateResolver,
                                        eventSink: eventSink,
                                        tileTraceRecorder: TileTraceRecorder(),
                                        baseLabelTraceRecorder: BaseLabelTraceRecorder(),
                                        clock: clock)
        guard let device = metalLayer.device else {
            throw ImmersiveMapVideoExportError.metalUnavailable
        }
        do {
            self.textureCache = try VideoExportPixelBufferTextureCache(device: device)
        } catch {
            throw ImmersiveMapVideoExportError.metalUnavailable
        }
    }

    func requestCancel() {
        cancelRequested = true
    }

    func run(shots: [ImmersiveMapCameraTourShot],
             progress: @escaping (ImmersiveMapVideoExportProgress) -> Void) async throws {
        // The runtime lives for exactly one export; on any exit the engine is
        // discarded: stop its tile loader and cut late event deliveries so an
        // orphaned load cannot delete valid disk entries or push stale state.
        defer { engine.prepareForDiscard() }
        let driver = TourVideoTimelineDriver(shots: shots,
                                             initialPosition: initialPosition,
                                             settings: settings,
                                             renderCamera: renderCamera,
                                             presentationStateResolver: presentationStateResolver)
        let plan = TourVideoTimelineDriver.makePlan(shots: shots,
                                                    initialPosition: initialPosition,
                                                    settings: settings,
                                                    framesPerSecond: configuration.framesPerSecond)
        do {
            progress(ImmersiveMapVideoExportProgress(phase: .preparing,
                                                     framesCompleted: 0,
                                                     totalFrames: plan.frameCount))
            try writer.start()
            try await preroll(driver: driver)

            for frameIndex in 0..<plan.frameCount {
                try checkCancelled()
                driver.advance(to: TimeInterval(frameIndex) * frameStepSeconds)
                advanceSceneTime()

                let pixelBuffer = try await writer.makePixelBuffer()
                let frame: VideoExportPixelBufferTextureCache.Frame
                do {
                    frame = try textureCache.makeFrame(wrapping: pixelBuffer)
                } catch {
                    throw ImmersiveMapVideoExportError.pixelBufferUnavailable
                }
                try await renderSettledFrame(into: frame.texture)
                if let markerOverlay, let markerSnapshot = eventSink.markerProjectionSnapshot {
                    // GPU work for this frame is complete (awaited above), so
                    // the CPU compositor can draw over the finished pixels.
                    markerOverlay.composite(into: frame.pixelBuffer, snapshot: markerSnapshot)
                }
                try await writer.append(frame.pixelBuffer, frameIndex: frameIndex)
                // The CoreVideo texture binding must survive until the GPU
                // finished (awaited above) and the buffer was appended.
                withExtendedLifetime(frame) {}

                progress(ImmersiveMapVideoExportProgress(phase: .rendering,
                                                         framesCompleted: frameIndex + 1,
                                                         totalFrames: plan.frameCount))
            }

            progress(ImmersiveMapVideoExportProgress(phase: .finishing,
                                                     framesCompleted: plan.frameCount,
                                                     totalFrames: plan.frameCount))
            try await writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
    }

    /// Settles the scene before the first captured frame: renders discarded
    /// frames with advancing scene time (label fades and avatar appear-fades
    /// need time to converge) until tiles, fades, the label visibility cycle,
    /// and avatar animations are quiet, or the readiness timeout expires.
    /// Avatar state is a detached copy, so its animations are finite by
    /// construction and cannot stall the pre-roll.
    private func preroll(driver: TourVideoTimelineDriver) async throws {
        driver.advance(to: 0)
        guard let scratchTexture = makeScratchTexture() else {
            throw ImmersiveMapVideoExportError.renderFrameFailure
        }
        let deadline = Date().addingTimeInterval(configuration.tileReadinessTimeout)
        while Date() < deadline {
            try checkCancelled()
            advanceSceneTime()
            try await renderOnce(into: scratchTexture)

            let hasPendingTiles = requestedTilesCount > 0
            let activity = eventSink.activityState
            let isSettled = hasPendingTiles == false
                && activity.labelFadeRenderingActive == false
                && activity.labelVisibilityCycleRenderingActive == false
                && activity.avatarAnimationRenderingActive == false
            if isSettled {
                break
            }
            if hasPendingTiles, eventSink.consumePendingInvalidation() == false {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        // Extra frame so globe-atlas changes staged by the last render are
        // committed before capture starts.
        advanceSceneTime()
        try await renderOnce(into: scratchTexture)
    }

    /// Renders the current frame, then (with scene time held, so fades and
    /// retention don't progress) re-renders whenever freshly materialized
    /// tiles arrive, until the viewport has no outstanding tiles or the
    /// per-frame readiness timeout expires.
    private func renderSettledFrame(into texture: MTLTexture) async throws {
        try await renderOnce(into: texture)
        guard requestedTilesCount > 0 else {
            return
        }

        let deadline = Date().addingTimeInterval(configuration.tileReadinessTimeout)
        var didRerender = false
        while requestedTilesCount > 0, Date() < deadline {
            try checkCancelled()
            if eventSink.consumePendingInvalidation() {
                try await renderOnce(into: texture)
                didRerender = true
            } else {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        if didRerender {
            // Settle frame: commits globe-atlas changes staged by the last
            // re-render into the captured pixels.
            try await renderOnce(into: texture)
        }
    }

    private func renderOnce(into texture: MTLTexture) async throws {
        var attempts = 0
        while true {
            try checkCancelled()
            let scheduled: Bool? = await withCheckedContinuation { continuation in
                // The export target is sized in output pixels and has no display
                // to ask how big a point is, so it composes for a fixed point
                // canvas and spends the rest of the resolution on detail: a 4K
                // export is a sharper 1080p export, not a wider one.
                let request = RenderFrameOffscreenRequest(texture: texture,
                                                          drawSize: drawSize,
                                                          pixelsPerPoint: exportPixelsPerPoint) { success in
                    continuation.resume(returning: success)
                }
                if engine.render(offscreen: request) == false {
                    // The completion handler never fires for a skipped frame.
                    continuation.resume(returning: nil)
                }
            }
            switch scheduled {
            case .some(true):
                return
            case .some(false):
                throw ImmersiveMapVideoExportError.renderFrameFailure
            case .none:
                attempts += 1
                guard attempts < 5 else {
                    throw ImmersiveMapVideoExportError.renderFrameFailure
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private var requestedTilesCount: Int {
        engine.currentDiagnostics?.counterValue(.requestedTiles) ?? 0
    }

    private func advanceSceneTime() {
        sceneTime += frameStepSeconds
        clock.setTime(sceneTime)
    }

    private func checkCancelled() throws {
        if cancelRequested || Task.isCancelled {
            throw ImmersiveMapVideoExportError.cancelled
        }
    }

    private func makeScratchTexture() -> MTLTexture? {
        guard let device = metalLayer.device else {
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: configuration.width,
                                                                  height: configuration.height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }
}

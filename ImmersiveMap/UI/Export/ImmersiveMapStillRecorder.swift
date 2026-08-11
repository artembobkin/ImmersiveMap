// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Metal
import QuartzCore

/// Renders one frame of the map offscreen and hands it back as a `CGImage`.
///
/// Standalone by design: it takes the settings, the camera and the content it
/// should draw, rather than attaching to a live map the way
/// ``ImmersiveMapTourVideoRecorder`` does. That makes it usable with no view on
/// screen at all, which is what generating thumbnails, share images or a batch
/// of reference renders needs.
///
/// Content is passed as values (routes, scene models, avatar markers) rather
/// than as controllers. A controller hands its state to a renderer as a
/// one-shot diff, so sharing one with a capture would drain the diff a live map
/// had not consumed yet, and a second capture from the same controller would
/// draw nothing. Values have no such history.
///
/// The frame is rendered by a second, headless engine, so an on-screen map
/// keeps its own state and stays interactive. The capture settles the scene
/// before taking the frame: it waits for the tiles its camera needs and lets
/// label fades converge, because a still has no later frame in which to
/// correct itself.
///
/// ```swift
/// let recorder = ImmersiveMapStillRecorder()
/// let image = try await recorder.capture(
///     settings: .default.earthScene(isEnabled: true),
///     camera: ImmersiveMapCameraPosition(latitudeDegrees: 55.75,
///                                        longitudeDegrees: 37.61,
///                                        zoom: 14),
///     configuration: ImmersiveMapStillConfiguration(width: 1280, height: 720))
/// ```
///
/// SwiftUI markers are platform views above the Metal layer and never draw in
/// Metal, so a capture cannot contain them. The attribution badge is host-view
/// chrome and does not appear either; add attribution before publishing
/// captured imagery.
///
/// On repeatability: pin ``ImmersiveMapStillConfiguration/sceneDate`` and two
/// captures of the same scene give the same picture. Settling takes however
/// many passes the scene needs, but the frame that is returned is always
/// rendered at one fixed scene time, so nothing animated by that clock (a
/// twinkling starfield, a fade partway through) can land on a different phase
/// between runs. Rasterization itself is not bit-identical on every GPU, so
/// compare captures with a small tolerance rather than byte for byte.
@MainActor
public final class ImmersiveMapStillRecorder {
    public private(set) var isCapturing = false

    public init() {}

    /// Renders one frame and returns it.
    ///
    /// - Parameters:
    ///   - settings: the map configuration to draw, including the tile
    ///     provider and style. The debug panel is host-view chrome and is
    ///     forced off for the capture.
    ///   - camera: where to look from. `nil` uses the same default position an
    ///     untouched map starts at.
    ///   - avatars: avatar markers to draw.
    ///   - routes: routes to draw.
    ///   - sceneModels: scene models to draw.
    ///   - configuration: output geometry and timing.
    /// - Throws: ``ImmersiveMapStillCaptureError``.
    public func capture(settings: ImmersiveMapSettings = .default,
                        camera: ImmersiveMapCameraPosition? = nil,
                        avatars: [AvatarMarker] = [],
                        routes: [ImmersiveMapRoute] = [],
                        sceneModels: [ImmersiveMapSceneModel] = [],
                        configuration: ImmersiveMapStillConfiguration = .default) async throws -> CGImage {
        guard isCapturing == false else {
            throw ImmersiveMapStillCaptureError.captureAlreadyInProgress
        }
        try configuration.validate()

        isCapturing = true
        defer { isCapturing = false }

        let runtime = try ImmersiveMapStillRuntime(settings: settings.debugPanel(false),
                                                   camera: camera,
                                                   avatars: avatars,
                                                   routes: routes,
                                                   sceneModels: sceneModels,
                                                   configuration: configuration)
        return try await runtime.captureImage()
    }
}

/// The headless engine behind one still: builds the render sources, settles the
/// scene, renders a frame, and reads it back into an image.
@MainActor
final class ImmersiveMapStillRuntime {
    /// How much scene time each settle pass covers.
    ///
    /// Larger than a frame on purpose. The loop is converging fades to their
    /// end state rather than animating them for anyone to watch, and a quarter
    /// second a pass gets there in a handful of renders instead of sixty.
    private static let sceneTimeStep: TimeInterval = 0.25

    /// Settle passes that run whatever the timeout says.
    ///
    /// `settleTimeout` bounds waiting on the network, and a caller who
    /// sets it to zero means "do not wait for tiles", not "hand me a frame
    /// where every label is still at zero opacity". Eight passes is two
    /// seconds of scene time, past any fade the style can configure.
    private static let minimumSettlePasses = 8

    /// Upper bound on settle passes, so scene time cannot outrun
    /// ``finalSceneTime``.
    private static let maximumSettlePasses = 200

    /// Scene time the captured frame is always taken at.
    ///
    /// This is what makes two captures of the same scene the same picture.
    /// Settling takes however many passes the scene needs, which depends on
    /// when tiles are demanded and when meshes land, so the clock would
    /// otherwise stop at a different place every run and everything animated
    /// by it would be caught mid-stride: the starfield twinkling, a fade
    /// halfway through. Pinning the last frame's time removes that.
    ///
    /// Chosen to sit past `maximumSettlePasses * sceneTimeStep`, since the
    /// scripted clock only moves forward.
    private static let finalSceneTime: TimeInterval = 60

    private final class StillAvatarSource: AvatarRenderSource {
        private let controller: ImmersiveMapAvatarsController?

        init(controller: ImmersiveMapAvatarsController?) {
            self.controller = controller
        }

        var currentAvatarController: ImmersiveMapAvatarsController? { controller }
    }

    private final class StillRouteSource: RouteRenderSource {
        private let controller: ImmersiveMapRoutesController?

        init(controller: ImmersiveMapRoutesController?) {
            self.controller = controller
        }

        var currentRoutesController: ImmersiveMapRoutesController? { controller }
    }

    private final class StillSceneModelSource: SceneModelRenderSource {
        private let controller: ImmersiveMapSceneModelsController?

        init(controller: ImmersiveMapSceneModelsController?) {
            self.controller = controller
        }

        var currentSceneModelsController: ImmersiveMapSceneModelsController? { controller }
    }

    private final class StillMarkerSource: MarkerRenderSource {
        var currentMarkerProjectionInput: MarkerProjectionInput { .empty }
    }

    private let configuration: ImmersiveMapStillConfiguration
    private let drawSize: CGSize
    private let clock: RenderFrameScriptedClock
    private let eventSink: VideoExportRenderEventSink
    private let avatarSource: StillAvatarSource
    private let markerSource: StillMarkerSource
    private let routeSource: StillRouteSource
    private let sceneModelSource: StillSceneModelSource
    private let renderCamera: FrameCameraStateResolver
    private let presentationStateResolver: MapPresentationStateController
    private let metalLayer: CAMetalLayer
    private let readback: OffscreenTextureImageReadback
    private let engine: RenderFrameEngine
    private var sceneTime: TimeInterval = 0

    init(settings: ImmersiveMapSettings,
         camera: ImmersiveMapCameraPosition?,
         avatars: [AvatarMarker],
         routes: [ImmersiveMapRoute],
         sceneModels: [ImmersiveMapSceneModel],
         configuration: ImmersiveMapStillConfiguration) throws {
        self.configuration = configuration
        self.drawSize = CGSize(width: configuration.width, height: configuration.height)

        let clock = RenderFrameScriptedClock(date: configuration.sceneDate ?? Date())
        self.clock = clock
        let eventSink = VideoExportRenderEventSink()
        self.eventSink = eventSink

        let renderCamera = FrameCameraStateResolver(settings: settings)
        self.renderCamera = renderCamera
        let presentationStateResolver = MapPresentationStateController(settings: settings)
        self.presentationStateResolver = presentationStateResolver

        // Position, then the presentation-derived clamp, in that order and
        // never one without the other. `setCameraPosition` limits zoom and the
        // global pitch ceiling but takes bearing verbatim; the globe's own
        // bearing and pitch limits are reachable only through
        // `applyConstraints`, and nothing later re-applies them. Without this,
        // a capture at zoom 2 with bearing 120 would render 120 degrees where
        // the live map and a video export both render 70, so the same
        // `ImmersiveMapCameraPosition` would give a different picture
        // depending on which of the three drew it.
        if let camera {
            renderCamera.setCameraPosition(camera)
            let constraints = presentationStateResolver
                .cameraConstraints(cameraState: renderCamera.currentCameraState())
            renderCamera.applyConstraints(constraints)
        }

        // Controllers built here and owned by this capture alone: their
        // snapshots are one-shot diffs, and sharing one with a live map would
        // take the state that map had not read yet.
        let avatarsController: ImmersiveMapAvatarsController?
        if avatars.isEmpty {
            avatarsController = nil
        } else {
            let controller = ImmersiveMapAvatarsController()
            avatars.forEach { controller.add($0) }
            avatarsController = controller
        }
        let routesController: ImmersiveMapRoutesController?
        if routes.isEmpty {
            routesController = nil
        } else {
            let controller = ImmersiveMapRoutesController()
            controller.add(routes)
            routesController = controller
        }
        let sceneModelsController: ImmersiveMapSceneModelsController?
        if sceneModels.isEmpty {
            sceneModelsController = nil
        } else {
            let controller = ImmersiveMapSceneModelsController()
            controller.add(sceneModels)
            sceneModelsController = controller
        }

        let avatarSource = StillAvatarSource(controller: avatarsController)
        let markerSource = StillMarkerSource()
        let routeSource = StillRouteSource(controller: routesController)
        let sceneModelSource = StillSceneModelSource(controller: sceneModelsController)
        self.avatarSource = avatarSource
        self.markerSource = markerSource
        self.routeSource = routeSource
        self.sceneModelSource = sceneModelSource

        // Device and pixel-format carrier only: the offscreen path never asks
        // this layer for a drawable.
        let metalLayer = CAMetalLayer()
        self.metalLayer = metalLayer
        self.engine = RenderFrameEngine(layer: metalLayer,
                                        avatarSource: avatarSource,
                                        markerSource: markerSource,
                                        sceneModelSource: sceneModelSource,
                                        routeSource: routeSource,
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
            throw ImmersiveMapStillCaptureError.metalUnavailable
        }
        self.readback = OffscreenTextureImageReadback(device: device)
    }

    func captureImage() async throws -> CGImage {
        // The runtime lives for exactly one capture, and on every exit the
        // engine is dropped: stop its tile loader and cut late event delivery
        // so an orphaned load cannot delete valid prepared-disk entries that a
        // live map shares, or push state into a dead store.
        defer { engine.prepareForDiscard() }

        let texture: MTLTexture
        do {
            texture = try readback.makeReadableTexture(width: configuration.width,
                                                       height: configuration.height)
        } catch {
            throw ImmersiveMapStillCaptureError.metalUnavailable
        }

        try await renderSettledFrame(into: texture)

        do {
            return try readback.makeImage(from: texture)
        } catch OffscreenTextureImageReadback.Failure.synchronizeFailed {
            throw ImmersiveMapStillCaptureError.renderFrameFailure
        } catch {
            throw ImmersiveMapStillCaptureError.imageCreationFailure
        }
    }

    // MARK: - Rendering

    /// Renders until the scene has stopped changing, then takes the frame.
    ///
    /// Scene time advances on every pass, which is the whole point and the
    /// thing a still cannot borrow from the per-frame path in video export.
    /// That one deliberately holds time still so fades do not run ahead
    /// between frames of a tour; here there is no next frame, so a held clock
    /// means the fades never start: `BaseLabelPresentationStateStore` seeds an
    /// entry at zero opacity and returns early unless time elapsed, so every
    /// label, POI sprite and road label would come out invisible.
    ///
    /// Settled means no outstanding tiles and no running fade or visibility
    /// cycle, which is the same condition the video export pre-roll uses
    /// before it starts capturing.
    private func renderSettledFrame(into texture: MTLTexture) async throws {
        let deadline = Date().addingTimeInterval(configuration.settleTimeout)
        var passes = 0
        while true {
            try checkCancelled()
            advanceSceneTime()
            try await renderOnce(into: texture)
            passes += 1

            let hasPendingWork = requestedTilesCount > 0 || pendingSceneModelMeshCount > 0
            let activity = eventSink.activityState
            let isSettled = hasPendingWork == false
                && activity.labelFadeRenderingActive == false
                && activity.labelVisibilityCycleRenderingActive == false
                && activity.avatarAnimationRenderingActive == false
            if isSettled {
                break
            }
            if passes >= Self.minimumSettlePasses, Date() >= deadline {
                break
            }
            if passes >= Self.maximumSettlePasses {
                break
            }
            // Invalidations are drained whatever is outstanding, not only when
            // tiles are: a scene model mesh finishing its load reports through
            // the same channel, and reading it only under a tile condition
            // would leave the loop sleeping through the news.
            if hasPendingWork, eventSink.consumePendingInvalidation() == false {
                try await sleep(milliseconds: 50)
            }
        }

        // The frame that gets read back, taken at a time that does not depend
        // on how long settling took, and one more render so globe-atlas
        // changes staged by the previous pass are committed into these pixels.
        clock.setTime(Self.finalSceneTime)
        sceneTime = Self.finalSceneTime
        try await renderOnce(into: texture)
        try await renderOnce(into: texture)
    }

    private func renderOnce(into texture: MTLTexture) async throws {
        var attempts = 0
        while true {
            try checkCancelled()
            let scheduled: Bool? = await withCheckedContinuation { continuation in
                let request = RenderFrameOffscreenRequest(texture: texture,
                                                          drawSize: drawSize,
                                                          pixelsPerPoint: configuration.pixelsPerPoint) { success in
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
                throw ImmersiveMapStillCaptureError.renderFrameFailure
            case .none:
                attempts += 1
                guard attempts < 5 else {
                    throw ImmersiveMapStillCaptureError.renderFrameFailure
                }
                try await sleep(milliseconds: 10)
            }
        }
    }

    /// `Task.sleep` throws `CancellationError`, which would escape a capture
    /// documented as throwing ``ImmersiveMapStillCaptureError`` and land a
    /// caller switching over that enum in its default branch.
    private func sleep(milliseconds: Int) async throws {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
        } catch {
            throw ImmersiveMapStillCaptureError.cancelled
        }
    }

    private func advanceSceneTime() {
        sceneTime += Self.sceneTimeStep
        clock.setTime(sceneTime)
    }

    private var requestedTilesCount: Int {
        engine.currentDiagnostics?.counterValue(.requestedTiles) ?? 0
    }

    /// Scene models whose mesh has not arrived yet.
    ///
    /// Meshes load on a detached task and raise no animation activity, and a
    /// still places its models statically, so nothing else in the settle
    /// condition would notice them missing: the capture would return the map
    /// without the models it was asked to draw, per model, silently. Video
    /// export sidesteps the same hazard by refusing scene models outright.
    private var pendingSceneModelMeshCount: Int {
        engine.currentDiagnostics?.counterValue(.pendingSceneModelMeshes) ?? 0
    }

    private func checkCancelled() throws {
        if Task.isCancelled {
            throw ImmersiveMapStillCaptureError.cancelled
        }
    }
}

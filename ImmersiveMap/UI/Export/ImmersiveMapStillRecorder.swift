// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Metal
import QuartzCore

/// Renders one frame of the map offscreen and hands it back as a `CGImage`.
///
/// Standalone by design: it takes the settings and the camera position it
/// should draw, rather than attaching to a live map the way
/// ``ImmersiveMapTourVideoRecorder`` does. That makes it usable with no view on
/// screen at all, which is what generating thumbnails, share images or a batch
/// of reference renders needs.
///
/// The frame is rendered by a second, headless engine, so an on-screen map
/// keeps its own state and stays interactive. The capture waits for the tiles
/// its camera needs (see
/// ``ImmersiveMapStillConfiguration/tileReadinessTimeout``) before taking the
/// frame, because a still has no later frame in which to correct itself.
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
/// The attribution badge is host-view chrome and does not appear in a capture.
/// Add attribution before publishing captured imagery.
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
    ///   - avatars: avatar markers to include. Pass the controller a live map
    ///     uses and its markers are drawn as they are on screen.
    ///   - routes: routes to include.
    ///   - sceneModels: scene models to include.
    ///   - configuration: output geometry and timing.
    /// - Throws: ``ImmersiveMapStillCaptureError``.
    public func capture(settings: ImmersiveMapSettings = .default,
                        camera: ImmersiveMapCameraPosition? = nil,
                        avatars: ImmersiveMapAvatarsController? = nil,
                        routes: ImmersiveMapRoutesController? = nil,
                        sceneModels: ImmersiveMapSceneModelsController? = nil,
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
/// tiles, renders a frame, and reads it back into an image.
@MainActor
final class ImmersiveMapStillRuntime {
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

    /// SwiftUI markers are platform views above the Metal layer and never draw
    /// in Metal, so a capture cannot contain them and does not pretend to.
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
    private let device: MTLDevice
    private let engine: RenderFrameEngine

    init(settings: ImmersiveMapSettings,
         camera: ImmersiveMapCameraPosition?,
         avatars: ImmersiveMapAvatarsController?,
         routes: ImmersiveMapRoutesController?,
         sceneModels: ImmersiveMapSceneModelsController?,
         configuration: ImmersiveMapStillConfiguration) throws {
        self.configuration = configuration
        self.drawSize = CGSize(width: configuration.width, height: configuration.height)

        let clock = RenderFrameScriptedClock(date: configuration.sceneDate ?? Date())
        self.clock = clock
        let eventSink = VideoExportRenderEventSink()
        self.eventSink = eventSink

        let renderCamera = FrameCameraStateResolver(settings: settings)
        if let camera {
            renderCamera.setCameraPosition(camera)
        }
        self.renderCamera = renderCamera
        let presentationStateResolver = MapPresentationStateController(settings: settings)
        self.presentationStateResolver = presentationStateResolver

        let avatarSource = StillAvatarSource(controller: avatars)
        let markerSource = StillMarkerSource()
        let routeSource = StillRouteSource(controller: routes)
        let sceneModelSource = StillSceneModelSource(controller: sceneModels)
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
        self.device = device
    }

    func captureImage() async throws -> CGImage {
        guard let texture = makeReadableTexture() else {
            throw ImmersiveMapStillCaptureError.metalUnavailable
        }
        clock.setTime(0)
        try await renderSettledFrame(into: texture)
        return try makeImage(from: texture)
    }

    // MARK: - Rendering

    /// Renders, then keeps re-rendering while tiles are still outstanding, up
    /// to the configured timeout.
    ///
    /// The loop is driven by the renderer's own invalidations rather than by a
    /// fixed number of frames: a tile that finishes loading invalidates, and
    /// only then is there anything new to draw.
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
                try await Task.sleep(for: .milliseconds(50))
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
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private var requestedTilesCount: Int {
        engine.currentDiagnostics?.counterValue(.requestedTiles) ?? 0
    }

    private func checkCancelled() throws {
        if Task.isCancelled {
            throw ImmersiveMapStillCaptureError.cancelled
        }
    }

    // MARK: - Readback

    /// A render target the CPU can read.
    ///
    /// Shared storage everywhere it exists, which is every Apple GPU and the
    /// simulator. A discrete GPU on an Intel Mac keeps its own copy, so the
    /// texture is managed there and its contents have to be synchronized back
    /// over the bus before `getBytes` sees them; without the distinction the
    /// capture would hand back an uninitialized image instead of failing.
    /// `.managed` exists only on macOS, hence the platform split rather than a
    /// bare `hasUnifiedMemory` test: the iOS Simulator also reports no unified
    /// memory and would be given a storage mode its platform does not have.
    private func makeReadableTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: configuration.width,
                                                                  height: configuration.height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        #if os(macOS)
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        #else
        descriptor.storageMode = .shared
        #endif
        return device.makeTexture(descriptor: descriptor)
    }

    private func synchronizeIfNeeded(_ texture: MTLTexture) throws {
        #if os(macOS)
        guard texture.storageMode == .managed else {
            return
        }
        guard let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw ImmersiveMapStillCaptureError.renderFrameFailure
        }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #endif
    }

    private func makeImage(from texture: MTLTexture) throws -> CGImage {
        try synchronizeIfNeeded(texture)

        let width = configuration.width
        let height = configuration.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }

        // The render target is `bgra8Unorm` with premultiplied alpha, which is
        // little-endian 32-bit with alpha first once the byte order is named.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo,
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw ImmersiveMapStillCaptureError.imageCreationFailure
        }
        return image
    }
}

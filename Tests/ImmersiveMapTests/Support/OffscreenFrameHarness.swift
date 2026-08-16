// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import QuartzCore
import XCTest

/// A headless `RenderFrameEngine` that draws into an `MTLTexture` and hands the
/// result back as pixels: the shared setup behind every end-to-end render test.
///
/// Everything below the engine is the real thing (shaders, subsystem graph,
/// passes, tile store); only the four render sources are stand-ins, and they
/// are stand-ins that own real controllers, so a test adds content by talking
/// to `routes`, `sceneModels` or `avatars` exactly as an app would.
///
/// Time comes from `RenderFrameScriptedClock` rather than the wall clock: a
/// frame rendered at a named instant is reproducible, which is what lets these
/// tests assert on the picture at all.
///
/// A compiled Metal library is required, so `makeOrSkip` skips under
/// `swift test` and runs in the xcodebuild workspace suite.
@MainActor
final class OffscreenFrameHarness {
    enum Failure: Error, CustomStringConvertible {
        case textureUnavailable
        case frameNotScheduled
        case frameFailedOnGPU
        case pictureNeverSettled(frames: Int)

        var description: String {
            switch self {
            case .textureUnavailable:
                return "The offscreen color texture could not be created"
            case .frameNotScheduled:
                return "The engine refused to schedule the offscreen frame"
            case .frameFailedOnGPU:
                return "The offscreen frame failed on the GPU"
            case let .pictureNeverSettled(frames):
                return "The picture was still changing after \(frames) frames"
            }
        }
    }

    // MARK: - Render sources

    private final class HarnessAvatarSource: AvatarRenderSource {
        let controller = ImmersiveMapAvatarsController()
        var currentAvatarController: ImmersiveMapAvatarsController? { controller }
    }

    private final class HarnessMarkerSource: MarkerRenderSource {
        var input: MarkerProjectionInput = .empty
        var currentMarkerProjectionInput: MarkerProjectionInput { input }
    }

    private final class HarnessSceneModelSource: SceneModelRenderSource {
        let controller = ImmersiveMapSceneModelsController()
        var currentSceneModelsController: ImmersiveMapSceneModelsController? { controller }
    }

    private final class HarnessRouteSource: RouteRenderSource {
        let controller = ImmersiveMapRoutesController()
        var currentRoutesController: ImmersiveMapRoutesController? { controller }
    }

    // MARK: - Contents

    let engine: RenderFrameEngine
    let clock: RenderFrameScriptedClock
    let camera: FrameCameraStateResolver
    let tileTraceRecorder: TileTraceRecorder
    /// Frame side in pixels. Frames are square: the globe sits in the middle of
    /// one, so every corner is equally far from it.
    let size: Int

    private let texture: MTLTexture
    private let avatarSource: HarnessAvatarSource
    private let markerSource: HarnessMarkerSource
    private let sceneModelSource: HarnessSceneModelSource
    private let routeSource: HarnessRouteSource

    var avatars: ImmersiveMapAvatarsController { avatarSource.controller }
    var sceneModels: ImmersiveMapSceneModelsController { sceneModelSource.controller }
    var routes: ImmersiveMapRoutesController { routeSource.controller }

    /// SwiftUI markers projected into the frame. Empty unless a test sets it.
    var markerInput: MarkerProjectionInput {
        get { markerSource.input }
        set { markerSource.input = newValue }
    }

    /// The tile store behind the engine, for tests that feed it tile bytes
    /// directly instead of going through the network loader.
    var tileRenderStore: TileRenderStore {
        engine.persistentContextForTesting.tileRenderStore
    }

    // MARK: - Setup

    /// - Parameter eventSink: pass a recording sink to inspect what the frame
    ///   publishes (selection snapshots, invalidations); the default discards
    ///   everything, which is what a pure pixel assertion needs.
    /// - Throws: `XCTSkip` when this machine cannot run a headless frame.
    static func makeOrSkip(settings: ImmersiveMapSettings = .default,
                           size: Int = 160,
                           date: Date = Date(timeIntervalSinceReferenceDate: 0),
                           eventSink: RenderFrameEventSink = VideoExportRenderEventSink()) throws -> OffscreenFrameHarness {
        _ = try requireMetalDeviceOrSkip()
        // No frame this harness renders can contain a tile it was not handed
        // directly: every offscreen test states that it renders an empty map,
        // and `FixtureTiles.tilelessSettings` makes that true. A test that
        // wants tiles hands them to `tileRenderStore` itself.
        //
        // Note what this costs: the settings go through the `tileProvider`
        // builder, so anything a caller set in `tiles.network` or
        // `tiles.coverage` is overwritten here. Nothing does today. The
        // previous version assigned `settings.tileProvider` alone and left
        // `tiles.network` untouched, which read as more conservative and was
        // in fact the bug: the transport takes its URL from `tiles.network`,
        // so the dead port never applied and this harness streamed tiles from
        // the hosted service while claiming to be offline.
        return try OffscreenFrameHarness(settings: FixtureTiles.tilelessSettings(settings),
                                         size: size,
                                         date: date,
                                         eventSink: eventSink)
    }

    /// The device a headless frame needs, or the way out: a skip normally, a
    /// failure when the run declared it requires Metal (see
    /// ``MetalTestEnvironment``).
    ///
    /// The harness reads its frames back on the CPU, so it needs a
    /// unified-memory GPU: that rules out the iOS Simulator, where these tests
    /// skip even under the requirement.
    @discardableResult
    static func requireMetalDeviceOrSkip() throws -> MTLDevice {
        try MetalTestEnvironment.requireDevice(needsReadback: true)
    }

    private init(settings: ImmersiveMapSettings,
                 size: Int,
                 date: Date,
                 eventSink: RenderFrameEventSink) throws {
        self.size = size
        self.clock = RenderFrameScriptedClock(date: date)
        self.camera = FrameCameraStateResolver(settings: settings)
        self.tileTraceRecorder = TileTraceRecorder()

        let avatarSource = HarnessAvatarSource()
        let markerSource = HarnessMarkerSource()
        let sceneModelSource = HarnessSceneModelSource()
        let routeSource = HarnessRouteSource()
        self.avatarSource = avatarSource
        self.markerSource = markerSource
        self.sceneModelSource = sceneModelSource
        self.routeSource = routeSource

        let layer = CAMetalLayer()
        self.engine = RenderFrameEngine(layer: layer,
                                        avatarSource: avatarSource,
                                        markerSource: markerSource,
                                        sceneModelSource: sceneModelSource,
                                        routeSource: routeSource,
                                        providerRuntime: ImmersiveMapProviderRuntimeContext(settings: settings),
                                        settings: settings,
                                        renderCamera: camera,
                                        presentationStateResolver: MapPresentationStateController(settings: settings),
                                        eventSink: eventSink,
                                        tileTraceRecorder: tileTraceRecorder,
                                        baseLabelTraceRecorder: BaseLabelTraceRecorder(),
                                        clock: clock)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let device = layer.device, let texture = device.makeTexture(descriptor: descriptor) else {
            throw Failure.textureUnavailable
        }
        self.texture = texture
    }

    // MARK: - Camera

    /// Moves the camera to `zoom` without disturbing where it is looking: the
    /// resolver's default position is already a sensible place to render, and a
    /// test that only cares about the presentation mode should not have to
    /// restate a coordinate to pick one.
    func setZoom(_ zoom: Double, pitch: Float = 0) {
        let current = camera.currentCameraPosition()
        camera.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: current.latitudeDegrees,
                                                            longitudeDegrees: current.longitudeDegrees,
                                                            zoom: zoom,
                                                            pitch: pitch))
    }

    var cameraPosition: ImmersiveMapCameraPosition {
        camera.currentCameraPosition()
    }

    func setCameraPosition(_ position: ImmersiveMapCameraPosition) {
        camera.setCameraPosition(position)
    }

    // MARK: - Rendering

    /// Scene time of the most recent frame. The scripted clock is monotonic,
    /// so this is the floor for whatever a test renders next.
    private(set) var lastFrameTime: TimeInterval = 0

    /// Renders the next frame one interval after the last one, for tests that
    /// continue after a wait whose length they did not choose.
    ///
    /// Deriving the time rather than naming it is what keeps the clock
    /// monotonic: a literal picked to sit after today's `renderUntilSettled`
    /// budget silently moves time backwards the day that budget grows.
    @discardableResult
    func renderNextFrame(after interval: TimeInterval = 1.0 / 60.0) async throws -> RenderedFrame {
        try await renderFrame(at: lastFrameTime + interval)
    }

    /// Renders one frame with scene time at `time` and reads the texture back.
    ///
    /// The scripted clock is monotonic, so `time` must never go backwards
    /// across calls on the same harness.
    @discardableResult
    func renderFrame(at time: TimeInterval = 0) async throws -> RenderedFrame {
        clock.setTime(time)
        lastFrameTime = time
        let didComplete = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let request = RenderFrameOffscreenRequest(texture: texture,
                                                      drawSize: CGSize(width: size, height: size),
                                                      pixelsPerPoint: 1) { success in
                continuation.resume(returning: success)
            }
            if engine.render(offscreen: request) == false {
                continuation.resume(returning: nil)
            }
        }
        guard let didComplete else {
            throw Failure.frameNotScheduled
        }
        guard didComplete else {
            throw Failure.frameFailedOnGPU
        }

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!,
                             bytesPerRow: size * 4,
                             from: MTLRegionMake2D(0, 0, size, size),
                             mipmapLevel: 0)
        }
        return RenderedFrame(size: size, bytes: bytes)
    }

    /// Renders until the picture stops changing, for content that reaches the
    /// GPU asynchronously (mesh loading, tile materialization): the frame that
    /// requested the work does not yet contain it.
    ///
    /// Settled means two consecutive identical frames and, when `changedFrom`
    /// is given, a picture that has actually moved away from it: without that
    /// second condition the very first pair of not-yet-loaded frames would
    /// match and the wait would end before the content ever arrived.
    ///
    /// - Parameter startingAt: scene time of the first frame in the wait.
    func renderUntilSettled(changedFrom baseline: RenderedFrame? = nil,
                            startingAt startTime: TimeInterval = 0,
                            frameInterval: TimeInterval = 1.0 / 60.0,
                            maximumFrames: Int = 200,
                            pollInterval: Duration = .milliseconds(20)) async throws -> RenderedFrame {
        var previous: RenderedFrame?
        for frameIndex in 0 ..< maximumFrames {
            let frame = try await renderFrame(at: startTime + TimeInterval(frameIndex) * frameInterval)
            if frame == previous, baseline.map({ frame != $0 }) ?? true {
                return frame
            }
            previous = frame
            try await Task.sleep(for: pollInterval)
        }
        throw Failure.pictureNeverSettled(frames: maximumFrames)
    }

    /// Scene time of the frame `index` frames into a 60 fps sequence, for tests
    /// that render a handful of frames and want them evenly spaced.
    nonisolated static func frameTime(_ index: Int) -> TimeInterval {
        TimeInterval(index) / 60.0
    }
}

/// One offscreen frame, read back as BGRA bytes with alpha last.
struct RenderedFrame: Equatable {
    struct Pixel: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    let size: Int
    /// Four bytes per pixel in `bgra8Unorm` order, row by row from the top.
    let bytes: [UInt8]

    func pixel(x: Int, y: Int) -> Pixel {
        pixel(atByteOffset: (y * size + x) * 4)
    }

    var center: Pixel {
        pixel(x: size / 2, y: size / 2)
    }

    /// The four frame corners: with the subject centred, these are the last
    /// place anything painting the background would miss.
    var corners: [Pixel] {
        [
            pixel(x: 0, y: 0),
            pixel(x: size - 1, y: 0),
            pixel(x: 0, y: size - 1),
            pixel(x: size - 1, y: size - 1)
        ]
    }

    var allPixels: [Pixel] {
        stride(from: 0, to: bytes.count, by: 4).map(pixel(atByteOffset:))
    }

    func count(where isIncluded: (Pixel) -> Bool) -> Int {
        stride(from: 0, to: bytes.count, by: 4)
            .lazy
            .filter { isIncluded(self.pixel(atByteOffset: $0)) }
            .count
    }

    func contains(where isIncluded: (Pixel) -> Bool) -> Bool {
        stride(from: 0, to: bytes.count, by: 4)
            .contains { isIncluded(self.pixel(atByteOffset: $0)) }
    }

    /// Summed channel values over the whole frame: the cheapest measure of
    /// "the picture got darker", used by the shadow tests.
    var brightnessSum: Int {
        bytes.reduce(into: 0) { $0 += Int($1) }
    }

    /// How many bytes differ from `other`, for tests that only need to prove
    /// that two frames are not the same picture.
    ///
    /// Same-sized frames only: `zip` would otherwise compare the common prefix
    /// and report a small difference for two pictures that are not even the
    /// same shape.
    func differingByteCount(from other: RenderedFrame) -> Int {
        precondition(size == other.size, "Frames of different sizes are not comparable")
        return zip(bytes, other.bytes).count { $0 != $1 }
    }

    private func pixel(atByteOffset offset: Int) -> Pixel {
        Pixel(red: bytes[offset + 2],
              green: bytes[offset + 1],
              blue: bytes[offset],
              alpha: bytes[offset + 3])
    }
}

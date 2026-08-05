// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import QuartzCore
import XCTest

/// End-to-end shadow check: a tall obelisk model must darken a wide flat slab
/// placed north-east of it (the default light shines from the south-west), and
/// toggling `ShadowSettings.isEnabled` live must brighten/darken the frame.
/// Requires the compiled Metal library, so it skips under `swift test` and
/// runs in the xcodebuild workspace suite.
final class ShadowOffscreenRenderTests: XCTestCase {
    private final class StubAvatarSource: AvatarRenderSource {
        var currentAvatarController: ImmersiveMapAvatarsController? { nil }
    }

    private final class StubMarkerSource: MarkerRenderSource {
        var currentMarkerProjectionInput: MarkerProjectionInput { .empty }
    }

    private final class StubSceneModelSource: SceneModelRenderSource {
        let controller = ImmersiveMapSceneModelsController()
        var currentSceneModelsController: ImmersiveMapSceneModelsController? { controller }
    }

    @MainActor
    func testShadowToggleChangesSlabBrightness() async throws {
        guard let probeDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? probeDevice.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
        guard probeDevice.hasUnifiedMemory else {
            throw XCTSkip("Unified-memory GPU is required for direct texture readback")
        }

        let settings = ImmersiveMapSettings.default
        let clock = RenderFrameScriptedClock()
        let eventSink = VideoExportRenderEventSink()
        let renderCamera = FrameCameraStateResolver(settings: settings)
        let presentation = MapPresentationStateController(settings: settings)
        let sceneModelSource = StubSceneModelSource()
        let layer = CAMetalLayer()
        let engine = RenderFrameEngine(layer: layer,
                                       avatarSource: StubAvatarSource(),
                                       markerSource: StubMarkerSource(),
                                       sceneModelSource: sceneModelSource,
                                       routeSource: StubRouteSource(),
                                       providerRuntime: ImmersiveMapProviderRuntimeContext(settings: settings),
                                       settings: settings,
                                       renderCamera: renderCamera,
                                       presentationStateResolver: presentation,
                                       eventSink: eventSink,
                                       tileTraceRecorder: TileTraceRecorder(),
                                       baseLabelTraceRecorder: BaseLabelTraceRecorder(),
                                       clock: clock)
        let device = try XCTUnwrap(layer.device)

        // Zoom 16 keeps the flat presentation on (transition saturates at
        // zoom 7) and the resolver's 1000 m caster-height cap comfortably
        // above the 800 m obelisk.
        renderCamera.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                                  longitudeDegrees: 0,
                                                                  zoom: 16))

        let size = 128
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        let baseline = try await renderFrame(engine: engine, clock: clock, texture: texture, time: 0, size: size)

        // Caster: an 800 m obelisk with an 80 m footprint at the camera
        // center. Its shadow reaches ~(320 m E, 480 m N) at the tip.
        let obeliskURL = try writeObeliskOBJ()
        defer { try? FileManager.default.removeItem(at: obeliskURL) }
        sceneModelSource.controller.add(ImmersiveMapSceneModel(
            id: 1,
            source: ImmersiveMapSceneModel.Source(url: obeliskURL),
            coordinate: GeoCoordinate(latitude: 0, longitude: 0),
            fitDiameterMeters: 800))

        // Receiver: a 400x400 m slab, 4 m thick, centered mid-shadow to the
        // north-east (1 degree ~= 111.32 km at the equator).
        let slabURL = try writeSlabOBJ()
        defer { try? FileManager.default.removeItem(at: slabURL) }
        sceneModelSource.controller.add(ImmersiveMapSceneModel(
            id: 2,
            source: ImmersiveMapSceneModel.Source(url: slabURL),
            coordinate: GeoCoordinate(latitude: 240.0 / 111_320.0,
                                      longitude: 160.0 / 111_320.0),
            fitDiameterMeters: 400))

        // Meshes load asynchronously off-main: render until pixels change,
        // then until two consecutive frames match (both models settled).
        var lastPixels = baseline
        var settled = false
        for frameIndex in 1...200 where settled == false {
            let pixels = try await renderFrame(engine: engine,
                                               clock: clock,
                                               texture: texture,
                                               time: TimeInterval(frameIndex) / 60.0,
                                               size: size)
            settled = pixels != baseline && pixels == lastPixels
            lastPixels = pixels
            if settled == false {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        XCTAssertTrue(settled, "Both models must load and rasterize before the shadow comparison")

        let shadowsOnSum = brightnessSum(lastPixels)

        engine.applySettings(settings.shadows(isEnabled: false))
        let shadowsOffPixels = try await renderFrame(engine: engine, clock: clock, texture: texture,
                                                     time: 4.0, size: size)
        let shadowsOffSum = brightnessSum(shadowsOffPixels)

        XCTAssertGreaterThan(shadowsOffSum, shadowsOnSum,
                             "Disabling shadows must brighten the slab north-east of the obelisk")

        engine.applySettings(settings.shadows(isEnabled: true))
        let shadowsBackPixels = try await renderFrame(engine: engine, clock: clock, texture: texture,
                                                      time: 5.0, size: size)
        XCTAssertLessThan(brightnessSum(shadowsBackPixels), shadowsOffSum,
                          "Re-enabling shadows must darken the frame again")
    }

    @MainActor
    private func renderFrame(engine: RenderFrameEngine,
                             clock: RenderFrameScriptedClock,
                             texture: MTLTexture,
                             time: TimeInterval,
                             size: Int) async throws -> [UInt8] {
        clock.setTime(time)
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
        XCTAssertEqual(didComplete, true, "Offscreen frame must schedule and complete")

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!,
                             bytesPerRow: size * 4,
                             from: MTLRegionMake2D(0, 0, size, size),
                             mipmapLevel: 0)
        }
        return pixels
    }

    private func brightnessSum(_ pixels: [UInt8]) -> Int {
        pixels.reduce(into: 0) { $0 += Int($1) }
    }

    /// A tall thin column: 0.2x0.2 footprint, height 2 (the fit dimension).
    private func writeObeliskOBJ() throws -> URL {
        try writeOBJ(name: "shadow-obelisk", halfX: 0.1, height: 2.0, halfZ: 0.1)
    }

    /// A wide flat slab: 20x20 footprint (the fit dimension), height 0.2.
    private func writeSlabOBJ() throws -> URL {
        try writeOBJ(name: "shadow-slab", halfX: 10.0, height: 0.2, halfZ: 10.0)
    }

    private func writeOBJ(name: String, halfX: Double, height: Double, halfZ: Double) throws -> URL {
        let obj = """
        v -\(halfX) 0 -\(halfZ)
        v \(halfX) 0 -\(halfZ)
        v \(halfX) \(height) -\(halfZ)
        v -\(halfX) \(height) -\(halfZ)
        v -\(halfX) 0 \(halfZ)
        v \(halfX) 0 \(halfZ)
        v \(halfX) \(height) \(halfZ)
        v -\(halfX) \(height) \(halfZ)
        f 1 3 2
        f 1 4 3
        f 5 6 7
        f 5 7 8
        f 1 2 6
        f 1 6 5
        f 2 3 7
        f 2 7 6
        f 3 4 8
        f 3 8 7
        f 4 1 5
        f 4 5 8
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension("obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private final class StubRouteSource: RouteRenderSource {
    var currentRoutesController: ImmersiveMapRoutesController? { nil }
}

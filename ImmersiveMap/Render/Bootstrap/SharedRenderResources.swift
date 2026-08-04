// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import MetalKit

/// Process-wide immutable GPU resources shared by every renderer instance.
///
/// A new `ImmersiveMapView` used to rebuild all of this from scratch: the
/// shader library load, ~26 pipeline states, the MSDF text atlases (two PNG
/// decodes + uploads and two JSON metric decodes), the POI sprite
/// rasterization, and the procedural sphere/cap geometry. None of it depends
/// on anything that varies between views: the device is the system singleton,
/// the color format is always `bgra8Unorm` and the MSAA sample count is a pure
/// function of the device, so one set serves the whole process and a second
/// map view (or a settings-driven renderer recreation) skips the entire cost.
///
/// Everything held here is immutable after creation and is safe to read from
/// any thread (Metal objects are thread-safe for use; the Swift wrappers never
/// mutate after init). The cache itself is `@MainActor` because every renderer
/// creation path already runs on the main actor.
///
/// Deliberate trade-offs of process-lifetime caching:
/// - The set stays resident after the last map view goes away (the decoded
///   text atlases dominate at ~2×17 MB of private textures). That is the
///   point (the next view starts warm), but apps where the map is a rarely
///   visited screen pay the residency; a release-when-idle hook can be added
///   if that ever matters in practice.
/// - The device is resolved once. If the system default device can change
///   mid-process (Intel macOS with an external GPU), later renderers keep the
///   original device, unlike the old per-view bootstrap which re-resolved it.
@MainActor
final class SharedRenderResources {
    let device: MTLDevice
    let library: MTLLibrary
    let renderSampleCount: Int
    /// The one color format the engine renders in; `RendererSetup` stamps it
    /// onto every view's layer.
    let colorPixelFormat: MTLPixelFormat = .bgra8Unorm

    // MARK: - Depth states and fallback textures

    let extrudedDepthState: MTLDepthStencilState
    let globeCapDepthState: MTLDepthStencilState
    let depthDisabledState: MTLDepthStencilState
    /// Bound at the shadow-map slot when the shadow pass is skipped: receiver
    /// shaders reference the texture statically and Metal validation requires a
    /// bound depth texture even though strength = 0 skips the sampling branch.
    /// Depth textures cannot be filled from the CPU, so a one-time no-draw pass
    /// clears this 1x1 texture to 1.0 ("lit everywhere") at creation.
    let shadowFallbackTexture: MTLTexture

    // MARK: - Pipelines

    let polygonPipeline: PolygonsPipeline
    let tilePipeline: TilePipeline
    let globeTileTexturePipeline: TilePipeline
    let extrudedTilePipeline: ExtrudedTilePipeline
    let globePipeline: GlobePipeline
    let fxaaPipeline: FXAAPipeline
    let starfieldPipeline: StarfieldPipeline
    let sceneModelPipeline: SceneModelPipeline
    let tilePointScreenPipelines: TilePointScreenPipelines
    let roadLabelPlacementPipeline: RoadLabelPlacementPipeline

    // MARK: - Geometry and atlases

    let mapSurfaceGridBuffers: MapSurfaceGridBuffers
    let globeCap: GlobeCapRenderer.SharedResources
    let avatars: AvatarsRenderer.SharedResources
    let textRenderer: TextRenderer
    let poiSpriteAtlas: PoiSpriteAtlas

    // MARK: - Lifecycle

    private static var cached: SharedRenderResources?

    /// Returns the process-wide instance, creating it on first use.
    static func shared() -> SharedRenderResources {
        if let cached {
            return cached
        }
        let resources = SharedRenderResources()
        cached = resources
        return resources
    }

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device
        self.library = RendererSetup.makeLibrary(metalDevice: device, bundle: .module)
        self.renderSampleCount = RendererSetup.preferredRenderSampleCount(metalDevice: device)

        self.extrudedDepthState = device.makeDepthStencilState(descriptor: Self.makeSceneDepthDescriptor())!
        self.globeCapDepthState = device.makeDepthStencilState(descriptor: Self.makeGlobeCapDepthDescriptor())!
        self.depthDisabledState = device.makeDepthStencilState(descriptor: Self.makeDepthDisabledDescriptor())!
        self.shadowFallbackTexture = Self.makeShadowFallbackTexture(device: device)

        self.polygonPipeline = PolygonsPipeline(metalDevice: device,
                                                pixelFormat: colorPixelFormat,
                                                library: library)
        self.tilePipeline = TilePipeline(metalDevice: device,
                                         pixelFormat: colorPixelFormat,
                                         library: library,
                                         sampleCount: renderSampleCount)
        // The atlas variant renders into non-MSAA atlas pages, which share the
        // same color format as the drawable.
        self.globeTileTexturePipeline = TilePipeline(metalDevice: device,
                                                     pixelFormat: colorPixelFormat,
                                                     library: library)
        self.extrudedTilePipeline = ExtrudedTilePipeline(metalDevice: device,
                                                         pixelFormat: colorPixelFormat,
                                                         library: library,
                                                         sampleCount: renderSampleCount)
        self.globePipeline = GlobePipeline(metalDevice: device,
                                           pixelFormat: colorPixelFormat,
                                           library: library,
                                           sampleCount: renderSampleCount)
        self.fxaaPipeline = FXAAPipeline(metalDevice: device,
                                         pixelFormat: colorPixelFormat,
                                         library: library)
        self.starfieldPipeline = StarfieldPipeline(metalDevice: device,
                                                   pixelFormat: colorPixelFormat,
                                                   library: library,
                                                   sampleCount: renderSampleCount)
        self.sceneModelPipeline = SceneModelPipeline(metalDevice: device,
                                                     pixelFormat: colorPixelFormat,
                                                     library: library,
                                                     sampleCount: renderSampleCount)
        self.tilePointScreenPipelines = TilePointScreenPipelines(metalDevice: device, library: library)
        self.roadLabelPlacementPipeline = RoadLabelPlacementPipeline(metalDevice: device, library: library)

        self.mapSurfaceGridBuffers = RendererSetup.makeMapSurfaceGridBuffers(metalDevice: device)
        self.globeCap = GlobeCapRenderer.SharedResources.make(metalDevice: device,
                                                              pixelFormat: colorPixelFormat,
                                                              library: library,
                                                              sampleCount: renderSampleCount,
                                                              maxLatitude: WebMercatorMath.maxLatitudeRadians)
        self.avatars = AvatarsRenderer.SharedResources.make(metalDevice: device,
                                                            pixelFormat: colorPixelFormat,
                                                            library: library,
                                                            sampleCount: 1)
        self.textRenderer = TextRenderer(device: device,
                                         library: library,
                                         sampleCount: 1)
        self.poiSpriteAtlas = PoiSpriteAtlas(device: device)
    }

    // MARK: - Shadow fallback

    private static func makeShadowFallbackTexture(device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                  width: 1,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        texture.label = "ShadowFallbackTexture"

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.depthAttachment.texture = texture
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.storeAction = .store
        passDescriptor.depthAttachment.clearDepth = 1.0
        // A throwaway queue: the clear runs once per process, before any view
        // samples the texture.
        if let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer(),
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
            encoder.endEncoding()
            commandBuffer.commit()
        }
        return texture
    }

    // MARK: - Depth descriptors

    private static func makeSceneDepthDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true
        return descriptor
    }

    private static func makeGlobeCapDepthDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }

    private static func makeDepthDisabledDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }
}

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
    /// Apple GPUs read the current framebuffer value in the fragment stage
    /// ([[color(n)]]), which lets the composited building path run inside the
    /// world pass through a memoryless attachment. Intel Macs and the
    /// simulator keep the two-pass path.
    let supportsFramebufferFetch: Bool

    // MARK: - Depth states and fallback textures

    let extrudedDepthState: MTLDepthStencilState
    let globeCapDepthState: MTLDepthStencilState
    /// The sky layers (the space background and the stars): drawn first on
    /// the sphere at the far plane, tested against the cleared depth without
    /// writing; the tile geometry blends over them.
    let skyBackdropDepthState: MTLDepthStencilState
    let depthDisabledState: MTLDepthStencilState
    /// The flat ground: tested against the depth the opaque buildings wrote
    /// before it (strictly closer wins, so a wall base never loses to the
    /// ground plane it stands on), never written, since every ground layer
    /// is blended and lies on the same plane. Under a solid building the
    /// ground fails the test before its fragment is shaded.
    let groundDepthState: MTLDepthStencilState
    /// For the framebuffer-fetch composite: every fragment passes and writes
    /// the far plane back, restoring the pre-building depth mid-pass so the
    /// scene models keep ignoring composited building depth.
    let compositeDepthResetState: MTLDepthStencilState
    /// The tile-priority stencil states (TileSourceStencilPriority): the
    /// sphere's opaque owner (rank depth written), the flat ground's owner
    /// (building depth tested, not written), and the shared non-owning test
    /// for translucent fills, ribbons and roads.
    let sphereOpaqueOwnerState: MTLDepthStencilState
    let groundOwnerState: MTLDepthStencilState
    let tileStencilTestState: MTLDepthStencilState
    /// Bound at the shadow-map slot when the shadow pass is skipped: receiver
    /// shaders reference the texture statically and Metal validation requires a
    /// bound depth texture even though strength = 0 skips the sampling branch.
    /// Depth textures cannot be filled from the CPU, so a one-time no-draw pass
    /// clears this 1x1 texture to 1.0 ("lit everywhere") at creation.
    let shadowFallbackTexture: MTLTexture
    /// Bound at the ground shadow mask slot of the flat ground pipeline when
    /// the mask pass did not run this frame: the shader guards the read with
    /// the disabled uniform's zero strength, but the binding itself is
    /// mandatory. A 1x1 "lit" texel, filled from the CPU.
    let groundShadowMaskFallbackTexture: MTLTexture

    // MARK: - Pipelines

    let polygonPipeline: PolygonsPipeline
    let tilePipeline: TilePipeline
    /// The tile geometry drawn straight onto the sphere in the world pass.
    let globeVectorSurfacePipeline: TilePipeline
    let extrudedTilePipeline: ExtrudedTilePipeline
    let groundShadowMaskPipeline: GroundShadowMaskPipeline
    let fxaaPipeline: FXAAPipeline
    let starfieldPipeline: StarfieldPipeline
    let atmospherePipeline: AtmospherePipeline
    let sceneModelPipeline: SceneModelPipeline
    let routePipeline: RoutePipeline
    let tilePointScreenPipelines: TilePointScreenPipelines
    let roadLabelPlacementPipeline: RoadLabelPlacementPipeline

    // MARK: - Geometry and atlases

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
        #if targetEnvironment(simulator)
        self.supportsFramebufferFetch = false
        #else
        self.supportsFramebufferFetch = device.supportsFamily(.apple1)
        #endif

        self.extrudedDepthState = device.makeDepthStencilState(descriptor: Self.makeSceneDepthDescriptor())!
        self.globeCapDepthState = device.makeDepthStencilState(descriptor: Self.makeGlobeCapDepthDescriptor())!
        self.skyBackdropDepthState = device.makeDepthStencilState(descriptor: Self.makeSkyBackdropDepthDescriptor())!
        self.depthDisabledState = device.makeDepthStencilState(descriptor: Self.makeDepthDisabledDescriptor())!
        self.groundDepthState = device.makeDepthStencilState(descriptor: Self.makeGroundDepthDescriptor())!
        self.compositeDepthResetState = device.makeDepthStencilState(descriptor: Self.makeCompositeDepthResetDescriptor())!
        self.sphereOpaqueOwnerState = device.makeDepthStencilState(descriptor: Self.makeSphereOpaqueOwnerDescriptor())!
        self.groundOwnerState = device.makeDepthStencilState(descriptor: Self.makeGroundOwnerDescriptor())!
        self.tileStencilTestState = device.makeDepthStencilState(descriptor: Self.makeTileStencilTestDescriptor())!
        self.shadowFallbackTexture = Self.makeShadowFallbackTexture(device: device)
        self.groundShadowMaskFallbackTexture = Self.makeGroundShadowMaskFallbackTexture(device: device)

        let compiled = Self.makeConcurrentlyCompiledResources(device: device,
                                                              library: library,
                                                              pixelFormat: colorPixelFormat,
                                                              sampleCount: renderSampleCount,
                                                              supportsFramebufferFetch: supportsFramebufferFetch)
        self.polygonPipeline = compiled.polygonPipeline
        self.tilePipeline = compiled.tilePipeline
        self.globeVectorSurfacePipeline = compiled.globeVectorSurfacePipeline
        self.extrudedTilePipeline = compiled.extrudedTilePipeline
        self.groundShadowMaskPipeline = compiled.groundShadowMaskPipeline
        self.fxaaPipeline = compiled.fxaaPipeline
        self.starfieldPipeline = compiled.starfieldPipeline
        self.atmospherePipeline = compiled.atmospherePipeline
        self.sceneModelPipeline = compiled.sceneModelPipeline
        self.routePipeline = compiled.routePipeline
        self.tilePointScreenPipelines = compiled.tilePointScreenPipelines
        self.roadLabelPlacementPipeline = compiled.roadLabelPlacementPipeline
        self.globeCap = compiled.globeCap
        self.avatars = compiled.avatars
        self.textRenderer = compiled.textRenderer

        // SF Symbol rasterization goes through UIImage/NSImage and stays on
        // the calling (main) thread rather than joining the concurrent batch.
        self.poiSpriteAtlas = PoiSpriteAtlas(device: device)
    }

    // MARK: - Concurrent pipeline compilation

    /// The pipeline groups and shared resources whose construction touches
    /// only the device and the library.
    private struct ConcurrentlyCompiledResources {
        let polygonPipeline: PolygonsPipeline
        let tilePipeline: TilePipeline
        let globeVectorSurfacePipeline: TilePipeline
        let extrudedTilePipeline: ExtrudedTilePipeline
        let groundShadowMaskPipeline: GroundShadowMaskPipeline
        let fxaaPipeline: FXAAPipeline
        let starfieldPipeline: StarfieldPipeline
        let atmospherePipeline: AtmospherePipeline
        let sceneModelPipeline: SceneModelPipeline
        let routePipeline: RoutePipeline
        let tilePointScreenPipelines: TilePointScreenPipelines
        let roadLabelPlacementPipeline: RoadLabelPlacementPipeline
        let globeCap: GlobeCapRenderer.SharedResources
        let avatars: AvatarsRenderer.SharedResources
        let textRenderer: TextRenderer
    }

    /// Compiles the ~29 pipeline states (and the device-only shared resources
    /// around them) on all cores instead of serializing them on the main
    /// thread. `MTLDevice` and `MTLLibrary` are thread-safe, every job below
    /// writes exactly one captured variable of its own, and
    /// `concurrentPerform` returns only after all iterations finished, so the
    /// collection at the end observes fully initialized values. The set of
    /// created resources and the synchronous-before-first-frame contract are
    /// unchanged.
    private nonisolated static func makeConcurrentlyCompiledResources(
        device: MTLDevice,
        library: MTLLibrary,
        pixelFormat: MTLPixelFormat,
        sampleCount: Int,
        supportsFramebufferFetch: Bool
    ) -> ConcurrentlyCompiledResources {
        var polygonPipeline: PolygonsPipeline?
        var tilePipeline: TilePipeline?
        var globeVectorSurfacePipeline: TilePipeline?
        var extrudedTilePipeline: ExtrudedTilePipeline?
        var groundShadowMaskPipeline: GroundShadowMaskPipeline?
        var fxaaPipeline: FXAAPipeline?
        var starfieldPipeline: StarfieldPipeline?
        var atmospherePipeline: AtmospherePipeline?
        var sceneModelPipeline: SceneModelPipeline?
        var routePipeline: RoutePipeline?
        var tilePointScreenPipelines: TilePointScreenPipelines?
        var roadLabelPlacementPipeline: RoadLabelPlacementPipeline?
        var globeCap: GlobeCapRenderer.SharedResources?
        var avatars: AvatarsRenderer.SharedResources?
        var textRenderer: TextRenderer?

        let jobs: [() -> Void] = [
            // The heaviest groups go first so they overlap the whole batch.
            { textRenderer = TextRenderer(device: device,
                                          library: library,
                                          sampleCount: 1) },
            { avatars = AvatarsRenderer.SharedResources.make(metalDevice: device,
                                                             pixelFormat: pixelFormat,
                                                             library: library,
                                                             sampleCount: 1) },
            { globeCap = GlobeCapRenderer.SharedResources.make(metalDevice: device,
                                                               pixelFormat: pixelFormat,
                                                               library: library,
                                                               sampleCount: sampleCount,
                                                               maxLatitude: WebMercatorMath.maxLatitudeRadians) },
            { extrudedTilePipeline = ExtrudedTilePipeline(metalDevice: device,
                                                          pixelFormat: pixelFormat,
                                                          library: library,
                                                          sampleCount: sampleCount,
                                                          supportsFramebufferFetch: supportsFramebufferFetch) },
            { polygonPipeline = PolygonsPipeline(metalDevice: device,
                                                 pixelFormat: pixelFormat,
                                                 library: library) },
            { tilePipeline = TilePipeline(metalDevice: device,
                                          pixelFormat: pixelFormat,
                                          library: library,
                                          sampleCount: sampleCount,
                                          supportsFramebufferFetch: supportsFramebufferFetch,
                                          readsGroundShadowMask: true) },
            { groundShadowMaskPipeline = GroundShadowMaskPipeline(metalDevice: device, library: library) },
            { globeVectorSurfacePipeline = TilePipeline(metalDevice: device,
                                                        pixelFormat: pixelFormat,
                                                        library: library,
                                                        sampleCount: sampleCount,
                                                        surface: .sphere) },
            { fxaaPipeline = FXAAPipeline(metalDevice: device,
                                          pixelFormat: pixelFormat,
                                          library: library) },
            { starfieldPipeline = StarfieldPipeline(metalDevice: device,
                                                    pixelFormat: pixelFormat,
                                                    library: library,
                                                    sampleCount: sampleCount) },
            { atmospherePipeline = AtmospherePipeline(metalDevice: device,
                                                      pixelFormat: pixelFormat,
                                                      library: library,
                                                      sampleCount: sampleCount) },
            { sceneModelPipeline = SceneModelPipeline(metalDevice: device,
                                                      pixelFormat: pixelFormat,
                                                      library: library,
                                                      sampleCount: sampleCount,
                                                      supportsFramebufferFetch: supportsFramebufferFetch) },
            { routePipeline = RoutePipeline(metalDevice: device,
                                            pixelFormat: pixelFormat,
                                            library: library,
                                            sampleCount: sampleCount) },
            { tilePointScreenPipelines = TilePointScreenPipelines(metalDevice: device, library: library) },
            { roadLabelPlacementPipeline = RoadLabelPlacementPipeline(metalDevice: device, library: library) }
        ]
        DispatchQueue.concurrentPerform(iterations: jobs.count) { jobs[$0]() }

        return ConcurrentlyCompiledResources(
            polygonPipeline: polygonPipeline!,
            tilePipeline: tilePipeline!,
            globeVectorSurfacePipeline: globeVectorSurfacePipeline!,
            extrudedTilePipeline: extrudedTilePipeline!,
            groundShadowMaskPipeline: groundShadowMaskPipeline!,
            fxaaPipeline: fxaaPipeline!,
            starfieldPipeline: starfieldPipeline!,
            atmospherePipeline: atmospherePipeline!,
            sceneModelPipeline: sceneModelPipeline!,
            routePipeline: routePipeline!,
            tilePointScreenPipelines: tilePointScreenPipelines!,
            roadLabelPlacementPipeline: roadLabelPlacementPipeline!,
            globeCap: globeCap!,
            avatars: avatars!,
            textRenderer: textRenderer!
        )
    }

    // MARK: - Shadow fallback

    /// One lit texel for the ground pipeline's mask slot on frames without
    /// the mask pass. A color texture, so it can be filled from the CPU.
    private static func makeGroundShadowMaskFallbackTexture(device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GroundShadowMaskPipeline.pixelFormat,
                                                                  width: 1,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        #if os(macOS)
        descriptor.storageMode = .managed
        #else
        descriptor.storageMode = .shared
        #endif
        let texture = device.makeTexture(descriptor: descriptor)!
        texture.label = "GroundShadowMaskFallbackTexture"
        var lit: UInt8 = 255
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &lit, bytesPerRow: 1)
        return texture
    }

    private static func makeShadowFallbackTexture(device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = ShadowCascadeAtlas.depthPixelFormat
        descriptor.width = 1
        descriptor.height = 1
        descriptor.arrayLength = ShadowCascadeAtlas.cascadeCount
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        texture.label = "ShadowFallbackTexture"

        // A throwaway queue: the clear runs once per process, before any view
        // samples the texture.
        guard let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer() else {
            return texture
        }
        let clearPasses = makeShadowFallbackClearDescriptors(
            texture: texture,
            supportsLayeredRendering: ShadowCascadeAtlas.supportsLayeredRendering(device: device)
        )
        for passDescriptor in clearPasses {
            commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)?.endEncoding()
        }
        commandBuffer.commit()
        return texture
    }

    /// The no-draw passes that leave every cascade slice of the fallback
    /// texture cleared to the far plane.
    ///
    /// With layered rendering that is one pass writing all slices. Without it
    /// each slice is cleared by its own pass: a descriptor asking for more
    /// than one slice does not fail softly there, it fails Metal validation
    /// and takes the process down, which is what used to happen at launch on
    /// the iOS Simulator. Every receiver samples this texture while shadows
    /// are off, so it has to arrive cleared either way.
    static func makeShadowFallbackClearDescriptors(texture: MTLTexture,
                                                   supportsLayeredRendering: Bool) -> [MTLRenderPassDescriptor] {
        func makeDescriptor() -> MTLRenderPassDescriptor {
            let passDescriptor = MTLRenderPassDescriptor()
            passDescriptor.depthAttachment.texture = texture
            passDescriptor.depthAttachment.loadAction = .clear
            passDescriptor.depthAttachment.storeAction = .store
            passDescriptor.depthAttachment.clearDepth = 1.0
            return passDescriptor
        }

        guard supportsLayeredRendering else {
            return (0..<ShadowCascadeAtlas.cascadeCount).map { slice in
                let passDescriptor = makeDescriptor()
                passDescriptor.depthAttachment.slice = slice
                return passDescriptor
            }
        }
        let passDescriptor = makeDescriptor()
        passDescriptor.renderTargetArrayLength = ShadowCascadeAtlas.cascadeCount
        return [passDescriptor]
    }

    // MARK: - Depth descriptors

    private static func makeCompositeDepthResetDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = true
        return descriptor
    }

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

    private static func makeSkyBackdropDepthDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }

    private static func makeGroundDepthDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .less
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }

    /// The tile-priority stencil (TileSourceStencilPriority): every tile
    /// pass tests greaterEqual against the finest painter's mark, and the
    /// owner passes replace it where they pass both tests, so a coarser
    /// substitute's overflow is rejected wherever a finer tile painted.
    private static func makeTilePriorityStencil(writes: Bool) -> MTLStencilDescriptor {
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .greaterEqual
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        stencil.depthStencilPassOperation = writes ? .replace : .keep
        return stencil
    }

    /// The sphere's opaque ground pass: the layer-rank depth (lessEqual,
    /// written) plus the owning tile-priority stencil write.
    private static func makeSphereOpaqueOwnerDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = makeSceneDepthDescriptor()
        descriptor.frontFaceStencil = makeTilePriorityStencil(writes: true)
        descriptor.backFaceStencil = makeTilePriorityStencil(writes: true)
        return descriptor
    }

    /// The flat ground's opaque pass: tested against the buildings' depth
    /// (the rank band is farther than every real fragment, so the test
    /// still rejects everything under a building), WRITING the band so a
    /// pixel is shaded once by its topmost opaque layer, and owning the
    /// tile-priority stencil.
    private static func makeGroundOwnerDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = makeGroundDepthDescriptor()
        descriptor.isDepthWriteEnabled = true
        descriptor.frontFaceStencil = makeTilePriorityStencil(writes: true)
        descriptor.backFaceStencil = makeTilePriorityStencil(writes: true)
        return descriptor
    }

    /// Every non-owning tile pass (translucent fills, ribbons, roads): the
    /// ground depth test plus the tile-priority stencil test, no writes.
    private static func makeTileStencilTestDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = makeGroundDepthDescriptor()
        descriptor.frontFaceStencil = makeTilePriorityStencil(writes: false)
        descriptor.backFaceStencil = makeTilePriorityStencil(writes: false)
        return descriptor
    }

    private static func makeDepthDisabledDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }
}

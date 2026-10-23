// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Process-wide immutable GPU resources shared by every renderer instance.
///
/// A new `ImmersiveMapView` used to rebuild all of this from scratch: the
/// shader library load, ~26 pipeline states, the MSDF text atlases (two raw
/// pixel uploads and two JSON metric decodes), the POI sprite
/// rasterization, and the procedural sphere/cap geometry. None of it depends
/// on anything that varies between views but the sample count: the device is
/// the system singleton and the color format is always `bgra8Unorm`, so one
/// set per sample count serves the whole process and a second map view (or a
/// settings-driven renderer recreation) skips the entire cost.
///
/// Everything held here is immutable after creation and is safe to read from
/// any thread (Metal objects are thread-safe for use; the Swift wrappers never
/// mutate after init). The cache itself is `@MainActor` because every renderer
/// creation path already runs on the main actor; the build behind it runs
/// on a detached task (`resources(sampleCount:)`, `prewarm(sampleCount:)`),
/// so the first map view of a process, or an app that prewarms at launch,
/// never stalls the main thread on shader pipelines and atlases.
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
    /// The label passes: lessEqual with the write on. The labels rasterize
    /// at the far plane and their fragments write one of two depths just
    /// short of it (TextShader.metal), fill nearer than halo, so a later
    /// glyph's halo never covers an earlier glyph's fill.
    let labelDepthState: MTLDepthStencilState
    let globeCapDepthState: MTLDepthStencilState
    /// The sky layers (the space background and the stars): drawn first on
    /// the sphere at the far plane, tested against the cleared depth without
    /// writing; the tile geometry blends over them.
    let skyBackdropDepthState: MTLDepthStencilState
    /// The horizon layer's ground side: the far-plane fragment passes only
    /// where something wrote a nearer depth (the ground's rank band), never
    /// written, and not where a building or a model raised the surface mask
    /// bit, so the haze reaches the painted ground alone and the sky side
    /// keeps the rest.
    let horizonGroundDepthState: MTLDepthStencilState
    /// The world-pass scene models: scene depth plus the surface mask write
    /// (see `TileSourceStencilPriority.surfaceMaskBit`).
    let sceneModelSurfaceMaskState: MTLDepthStencilState
    /// The four draws of a scene model that cuts into the ground (see
    /// `TileSourceStencilPriority.groundHoleBit` and SceneModel.metal).
    let sceneModelGroundCutStates: SceneModelGroundCutStates
    let depthDisabledState: MTLDepthStencilState
    /// The flat ground: tested against the depth the opaque buildings wrote
    /// before it (strictly closer wins, so a wall base never loses to the
    /// ground plane it stands on), never written, since every ground layer
    /// is blended and lies on the same plane. Under a solid building the
    /// ground fails the test before its fragment is shaded.
    let groundDepthState: MTLDepthStencilState
    /// The tile-priority stencil states (TileSourceStencilPriority), every
    /// one testing `equal` to the source's zoom, the planner's mark, and
    /// none writing the priority: the sphere's opaque ground (scene depth
    /// written) and the non-owning test for the translucent fills, the
    /// ribbons, the flat road edge lines and the bridge overlay of either
    /// surface. `sphereRibbonOwnerState` is the sphere's ribbon cores: the
    /// rank depth written under a strict test (`makeSphereRibbonOwnerDescriptor`).
    let sphereOpaqueOwnerState: MTLDepthStencilState
    let sphereRibbonOwnerState: MTLDepthStencilState
    let tileStencilTestState: MTLDepthStencilState
    /// The flat ground's opaque pass: the ground depth written, so a pixel
    /// is shaded once by its topmost opaque layer, under the tile-priority
    /// test.
    let groundOwnerState: MTLDepthStencilState
    /// The flat road buckets: the rank depth tested and written
    /// (`RoadRankDepth`), under the tile-priority test.
    let roadRankState: MTLDepthStencilState
    /// The world-pass buildings: the scene depth (lessEqual, written, for
    /// their own walls and roofs) plus the tile-priority stencil test, which
    /// replaces the old per-placement slot clip.
    let extrudedStencilTestState: MTLDepthStencilState
    /// The placement prepass (`PlacementStencilRenderSubsystem`): the depth
    /// neither tested nor written, the source's zoom written into the
    /// priority bits.
    let placementStencilWriteState: MTLDepthStencilState
    /// The placement prepass on the relief (`PlacementStencilRenderSubsystem`):
    /// first the ground's depth, every point once, the stencil untouched,
    /// then the marks tested against that depth and writing none.
    let placementDepthWriteState: MTLDepthStencilState
    let placementStencilReliefWriteState: MTLDepthStencilState
    /// The prepass's depth reset: the depth written whatever is there, the
    /// stencil untouched.
    let placementDepthResetState: MTLDepthStencilState
    /// Bound at the shadow-map slot when the shadow pass is skipped: receiver
    /// shaders reference the texture statically and Metal validation requires a
    /// bound depth texture even though strength = 0 skips the sampling branch.
    /// Depth textures cannot be filled from the CPU, so a one-time no-draw pass
    /// clears this 1x1 texture to 1.0 ("lit everywhere") at creation.
    let shadowFallbackTexture: MTLTexture
    /// Bound at the scene depth slot of the road labels on a frame whose
    /// depth was not kept for them (`RoadLabelDrawSubsystem`): the shader
    /// skips the read when the uniform says so, but the binding itself is
    /// mandatory, and it has to be a plain `depth2d`, which the shadow map's
    /// texture array is not. A 1x1 depth texture cleared to the far plane.
    let sceneDepthFallbackTexture: MTLTexture
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
    /// The labels painted on the map, in the world pass on both surfaces.
    let surfaceLabelPipeline: SurfaceLabelPipeline
    let extrudedTilePipeline: ExtrudedTilePipeline
    /// The raster tiles: their bake and their draws on both surfaces.
    let rasterTilePipeline: RasterTilePipeline
    let groundShadowMaskPipeline: GroundShadowMaskPipeline
    let fxaaPipeline: FXAAPipeline
    let starfieldPipeline: StarfieldPipeline
    /// The air around the surface's edge, on both surfaces.
    let horizonPipeline: HorizonPipeline
    let sceneModelPipeline: SceneModelPipeline
    /// The models of the model tiles, see `ModelTilePipeline`.
    let modelTilePipeline: ModelTilePipeline
    /// The trees of the woods and the parks, see `TreeRenderSubsystem`.
    let treePipeline: TreePipeline
    /// The layers of the app's data, see `LayerRenderSubsystem`.
    let layerPipeline: LayerPipeline
    /// The flat map's placement prepass, see `PlacementStencilRenderSubsystem`.
    let placementStencilPipeline: PlacementStencilPipeline

    // MARK: - Geometry and atlases

    let globeCap: GlobeCapRenderer.SharedResources
    let avatars: AvatarsRenderer.SharedResources
    let textRenderer: TextRenderer
    let poiSpriteAtlas: PoiSpriteAtlas

    // MARK: - Lifecycle

    private static var cached: [Int: SharedRenderResources] = [:]
    /// The builds in progress, one per resolved sample count, so a prewarm
    /// and the first map view that arrives while it runs share one build.
    private static var inFlight: [Int: Task<SharedRenderResources, Never>] = [:]
    /// Metal objects are thread-safe; the box carries the device into the
    /// background build under strict concurrency.
    private struct DeviceBox: @unchecked Sendable {
        let device: MTLDevice
    }
    private static let sharedDevice: DeviceBox? = MTLCreateSystemDefaultDevice().map(DeviceBox.init)

    private static func resolvedSampleCount(_ sampleCount: Int) -> (device: MTLDevice, sampleCount: Int) {
        guard let box = sharedDevice else {
            fatalError("Metal is not supported on this device")
        }
        return (box.device, RendererSetup.resolvedRenderSampleCount(requested: sampleCount, metalDevice: box.device))
    }

    /// Returns the process-wide instance for a sample count, creating it on
    /// the calling thread when nothing has built it yet. The count is the
    /// one the device can actually render with
    /// (`RendererSetup.resolvedRenderSampleCount`), so two requests the
    /// device resolves alike share one set. The synchronous path: the
    /// offscreen recorders and the tests take it; a map view goes through
    /// `resources(sampleCount:)` so the build never blocks the main thread.
    static func shared(sampleCount: Int = 1) -> SharedRenderResources {
        let (device, resolved) = resolvedSampleCount(sampleCount)
        if let cached = cached[resolved] {
            return cached
        }
        let resources = SharedRenderResources(built: Self.build(device: device, renderSampleCount: resolved))
        cached[resolved] = resources
        return resources
    }

    /// Whether `shared(sampleCount:)` would return without building.
    static func isAvailable(sampleCount: Int = 1) -> Bool {
        cached[resolvedSampleCount(sampleCount).sampleCount] != nil
    }

    /// The process-wide instance for a sample count, built off the main
    /// thread when it does not exist yet: the shader library, the pipeline
    /// states (which is where the device compiles the shaders, once per
    /// build, the system caching the binaries after that), the atlases and
    /// the geometry come together on a detached task, and only the SF
    /// Symbol sprite atlas, which rasterizes through UIImage/NSImage, is
    /// made here at the end. Concurrent callers await the same build; a
    /// synchronous `shared` call that lands in the meantime builds its own
    /// copy and wins, and the awaited build is then dropped in its favour.
    static func resources(sampleCount: Int = 1) async -> SharedRenderResources {
        let (device, resolved) = resolvedSampleCount(sampleCount)
        if let cached = cached[resolved] {
            return cached
        }
        if let inFlight = inFlight[resolved] {
            return await inFlight.value
        }
        let box = DeviceBox(device: device)
        let task = Task { @MainActor () -> SharedRenderResources in
            let built = await Task.detached(priority: .userInitiated) {
                Self.build(device: box.device, renderSampleCount: resolved)
            }.value
            if let cached = cached[resolved] {
                inFlight[resolved] = nil
                return cached
            }
            let resources = SharedRenderResources(built: built)
            cached[resolved] = resources
            inFlight[resolved] = nil
            return resources
        }
        inFlight[resolved] = task
        return await task.value
    }

    /// Builds the resources for a sample count ahead of the first map view,
    /// off the main thread; see `resources(sampleCount:)`. Returns when
    /// they are ready.
    static func prewarm(sampleCount: Int = 1) async {
        _ = await resources(sampleCount: sampleCount)
    }

    #if DEBUG
    /// Forgets the built set for a sample count, so a test can watch it
    /// being built again. Engines holding the old set keep it.
    static func dropCachedForTesting(sampleCount: Int) {
        let resolved = resolvedSampleCount(sampleCount).sampleCount
        cached[resolved] = nil
        inFlight[resolved] = nil
    }
    #endif

    /// Everything the build makes away from the main actor: immutable
    /// Metal objects and the engine's wrappers around them.
    private struct Built: @unchecked Sendable {
        let device: MTLDevice
        let library: MTLLibrary
        let renderSampleCount: Int
        let extrudedDepthState: MTLDepthStencilState
        let labelDepthState: MTLDepthStencilState
        let globeCapDepthState: MTLDepthStencilState
        let skyBackdropDepthState: MTLDepthStencilState
        let horizonGroundDepthState: MTLDepthStencilState
        let depthDisabledState: MTLDepthStencilState
        let groundDepthState: MTLDepthStencilState
        let sphereOpaqueOwnerState: MTLDepthStencilState
        let sphereRibbonOwnerState: MTLDepthStencilState
        let tileStencilTestState: MTLDepthStencilState
        let groundOwnerState: MTLDepthStencilState
        let roadRankState: MTLDepthStencilState
        let extrudedStencilTestState: MTLDepthStencilState
        let placementStencilWriteState: MTLDepthStencilState
        let placementDepthWriteState: MTLDepthStencilState
        let placementStencilReliefWriteState: MTLDepthStencilState
        let placementDepthResetState: MTLDepthStencilState
        let sceneModelSurfaceMaskState: MTLDepthStencilState
        let sceneModelGroundCutStates: SceneModelGroundCutStates
        let shadowFallbackTexture: MTLTexture
        let sceneDepthFallbackTexture: MTLTexture
        let groundShadowMaskFallbackTexture: MTLTexture
        let compiled: ConcurrentlyCompiledResources
    }

    private nonisolated static func build(device: MTLDevice, renderSampleCount: Int) -> Built {
        let library = RendererSetup.makeLibrary(metalDevice: device, bundle: .module)
        let compiled = Self.makeConcurrentlyCompiledResources(device: device,
                                                              library: library,
                                                              pixelFormat: .bgra8Unorm,
                                                              sampleCount: renderSampleCount)
        return Built(device: device,
                     library: library,
                     renderSampleCount: renderSampleCount,
                     extrudedDepthState: device.makeDepthStencilState(descriptor: Self.makeSceneDepthDescriptor())!,
                     labelDepthState: device.makeDepthStencilState(descriptor: Self.makeSceneDepthDescriptor())!,
                     globeCapDepthState: device.makeDepthStencilState(descriptor: Self.makeGlobeCapDepthDescriptor())!,
                     skyBackdropDepthState: device.makeDepthStencilState(descriptor: Self.makeSkyBackdropDepthDescriptor())!,
                     horizonGroundDepthState: device.makeDepthStencilState(descriptor: Self.makeHorizonGroundDepthDescriptor())!,
                     depthDisabledState: device.makeDepthStencilState(descriptor: Self.makeDepthDisabledDescriptor())!,
                     groundDepthState: device.makeDepthStencilState(descriptor: Self.makeGroundDepthDescriptor())!,
                     sphereOpaqueOwnerState: device.makeDepthStencilState(descriptor: Self.makeSphereOpaqueOwnerDescriptor())!,
                     sphereRibbonOwnerState: device.makeDepthStencilState(descriptor: Self.makeSphereRibbonOwnerDescriptor())!,
                     tileStencilTestState: device.makeDepthStencilState(descriptor: Self.makeTileStencilTestDescriptor())!,
                     groundOwnerState: device.makeDepthStencilState(descriptor: Self.makeGroundOwnerDescriptor())!,
                     roadRankState: device.makeDepthStencilState(descriptor: Self.makeRoadRankDescriptor())!,
                     extrudedStencilTestState: device.makeDepthStencilState(descriptor: Self.makeExtrudedStencilTestDescriptor())!,
                     placementStencilWriteState: device.makeDepthStencilState(descriptor: Self.makePlacementStencilWriteDescriptor())!,
                     placementDepthWriteState: device.makeDepthStencilState(descriptor: Self.makePlacementDepthWriteDescriptor())!,
                     placementStencilReliefWriteState: device.makeDepthStencilState(descriptor: Self.makePlacementStencilReliefWriteDescriptor())!,
                     placementDepthResetState: device.makeDepthStencilState(descriptor: Self.makePlacementDepthResetDescriptor())!,
                     sceneModelSurfaceMaskState: device.makeDepthStencilState(descriptor: Self.makeSceneModelSurfaceMaskDescriptor())!,
                     sceneModelGroundCutStates: SceneModelGroundCutStates(
                        holeWrite: device.makeDepthStencilState(descriptor: Self.makeSceneModelGroundHoleDescriptor(raises: true))!,
                        holeClear: device.makeDepthStencilState(descriptor: Self.makeSceneModelGroundHoleDescriptor(raises: false))!,
                        holeTest: device.makeDepthStencilState(descriptor: Self.makeSceneModelGroundHoleTestDescriptor())!),
                     shadowFallbackTexture: Self.makeShadowFallbackTexture(device: device),
                     sceneDepthFallbackTexture: Self.makeSceneDepthFallbackTexture(device: device),
                     groundShadowMaskFallbackTexture: Self.makeGroundShadowMaskFallbackTexture(device: device),
                     compiled: compiled)
    }

    private init(built: Built) {
        self.device = built.device
        self.library = built.library
        self.renderSampleCount = built.renderSampleCount
        self.extrudedDepthState = built.extrudedDepthState
        self.labelDepthState = built.labelDepthState
        self.globeCapDepthState = built.globeCapDepthState
        self.skyBackdropDepthState = built.skyBackdropDepthState
        self.horizonGroundDepthState = built.horizonGroundDepthState
        self.depthDisabledState = built.depthDisabledState
        self.groundDepthState = built.groundDepthState
        self.sphereOpaqueOwnerState = built.sphereOpaqueOwnerState
        self.sphereRibbonOwnerState = built.sphereRibbonOwnerState
        self.tileStencilTestState = built.tileStencilTestState
        self.groundOwnerState = built.groundOwnerState
        self.roadRankState = built.roadRankState
        self.extrudedStencilTestState = built.extrudedStencilTestState
        self.placementStencilWriteState = built.placementStencilWriteState
        self.placementDepthWriteState = built.placementDepthWriteState
        self.placementStencilReliefWriteState = built.placementStencilReliefWriteState
        self.placementDepthResetState = built.placementDepthResetState
        self.sceneModelSurfaceMaskState = built.sceneModelSurfaceMaskState
        self.sceneModelGroundCutStates = built.sceneModelGroundCutStates
        self.shadowFallbackTexture = built.shadowFallbackTexture
        self.sceneDepthFallbackTexture = built.sceneDepthFallbackTexture
        self.groundShadowMaskFallbackTexture = built.groundShadowMaskFallbackTexture

        let compiled = built.compiled
        self.polygonPipeline = compiled.polygonPipeline
        self.tilePipeline = compiled.tilePipeline
        self.globeVectorSurfacePipeline = compiled.globeVectorSurfacePipeline
        self.surfaceLabelPipeline = compiled.surfaceLabelPipeline
        self.extrudedTilePipeline = compiled.extrudedTilePipeline
        self.rasterTilePipeline = compiled.rasterTilePipeline
        self.groundShadowMaskPipeline = compiled.groundShadowMaskPipeline
        self.fxaaPipeline = compiled.fxaaPipeline
        self.starfieldPipeline = compiled.starfieldPipeline
        self.horizonPipeline = compiled.horizonPipeline
        self.sceneModelPipeline = compiled.sceneModelPipeline
        self.modelTilePipeline = compiled.modelTilePipeline
        self.treePipeline = compiled.treePipeline
        self.layerPipeline = compiled.layerPipeline
        self.placementStencilPipeline = compiled.placementStencilPipeline
        self.globeCap = compiled.globeCap
        self.avatars = compiled.avatars
        self.textRenderer = compiled.textRenderer

        // SF Symbol rasterization goes through UIImage/NSImage and stays on
        // the main thread rather than joining the background build.
        self.poiSpriteAtlas = PoiSpriteAtlas(device: built.device)
    }

    // MARK: - Concurrent pipeline compilation

    /// The pipeline groups and shared resources whose construction touches
    /// only the device and the library.
    private struct ConcurrentlyCompiledResources: @unchecked Sendable {
        let polygonPipeline: PolygonsPipeline
        let tilePipeline: TilePipeline
        let globeVectorSurfacePipeline: TilePipeline
        let surfaceLabelPipeline: SurfaceLabelPipeline
        let extrudedTilePipeline: ExtrudedTilePipeline
        let rasterTilePipeline: RasterTilePipeline
        let groundShadowMaskPipeline: GroundShadowMaskPipeline
        let fxaaPipeline: FXAAPipeline
        let starfieldPipeline: StarfieldPipeline
        let horizonPipeline: HorizonPipeline
        let sceneModelPipeline: SceneModelPipeline
        let modelTilePipeline: ModelTilePipeline
        let treePipeline: TreePipeline
        let layerPipeline: LayerPipeline
        let placementStencilPipeline: PlacementStencilPipeline
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
        sampleCount: Int
    ) -> ConcurrentlyCompiledResources {
        var polygonPipeline: PolygonsPipeline?
        var tilePipeline: TilePipeline?
        var globeVectorSurfacePipeline: TilePipeline?
        var surfaceLabelPipeline: SurfaceLabelPipeline?
        var extrudedTilePipeline: ExtrudedTilePipeline?
        var rasterTilePipeline: RasterTilePipeline?
        var groundShadowMaskPipeline: GroundShadowMaskPipeline?
        var fxaaPipeline: FXAAPipeline?
        var starfieldPipeline: StarfieldPipeline?
        var horizonPipeline: HorizonPipeline?
        var sceneModelPipeline: SceneModelPipeline?
        var modelTilePipeline: ModelTilePipeline?
        var treePipeline: TreePipeline?
        var layerPipeline: LayerPipeline?
        var placementStencilPipeline: PlacementStencilPipeline?
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
                                                          sampleCount: sampleCount) },
            { polygonPipeline = PolygonsPipeline(metalDevice: device,
                                                 pixelFormat: pixelFormat,
                                                 library: library) },
            { tilePipeline = TilePipeline(metalDevice: device,
                                          pixelFormat: pixelFormat,
                                          library: library,
                                          sampleCount: sampleCount,
                                          readsGroundShadowMask: true) },
            { groundShadowMaskPipeline = GroundShadowMaskPipeline(metalDevice: device, library: library) },
            { rasterTilePipeline = RasterTilePipeline(metalDevice: device,
                                                      pixelFormat: pixelFormat,
                                                      library: library,
                                                      sampleCount: sampleCount) },
            { globeVectorSurfacePipeline = TilePipeline(metalDevice: device,
                                                        pixelFormat: pixelFormat,
                                                        library: library,
                                                        sampleCount: sampleCount,
                                                        surface: .sphere) },
            { surfaceLabelPipeline = SurfaceLabelPipeline(metalDevice: device,
                                                          pixelFormat: pixelFormat,
                                                          library: library,
                                                          sampleCount: sampleCount) },
            { fxaaPipeline = FXAAPipeline(metalDevice: device,
                                          pixelFormat: pixelFormat,
                                          library: library) },
            { starfieldPipeline = StarfieldPipeline(metalDevice: device,
                                                    pixelFormat: pixelFormat,
                                                    library: library,
                                                    sampleCount: sampleCount) },
            { horizonPipeline = HorizonPipeline(metalDevice: device,
                                                pixelFormat: pixelFormat,
                                                library: library,
                                                sampleCount: sampleCount) },
            { sceneModelPipeline = SceneModelPipeline(metalDevice: device,
                                                      pixelFormat: pixelFormat,
                                                      library: library,
                                                      sampleCount: sampleCount) },
            { modelTilePipeline = ModelTilePipeline(metalDevice: device,
                                                    pixelFormat: pixelFormat,
                                                    library: library,
                                                    sampleCount: sampleCount) },
            { placementStencilPipeline = PlacementStencilPipeline(metalDevice: device,
                                                                  pixelFormat: pixelFormat,
                                                                  library: library,
                                                                  sampleCount: sampleCount) },
            { treePipeline = TreePipeline(metalDevice: device,
                                          pixelFormat: pixelFormat,
                                          library: library,
                                          sampleCount: sampleCount) },
            { layerPipeline = LayerPipeline(metalDevice: device,
                                            pixelFormat: pixelFormat,
                                            library: library,
                                            sampleCount: sampleCount) }
        ]
        DispatchQueue.concurrentPerform(iterations: jobs.count) { jobs[$0]() }

        return ConcurrentlyCompiledResources(
            polygonPipeline: polygonPipeline!,
            tilePipeline: tilePipeline!,
            globeVectorSurfacePipeline: globeVectorSurfacePipeline!,
            surfaceLabelPipeline: surfaceLabelPipeline!,
            extrudedTilePipeline: extrudedTilePipeline!,
            rasterTilePipeline: rasterTilePipeline!,
            groundShadowMaskPipeline: groundShadowMaskPipeline!,
            fxaaPipeline: fxaaPipeline!,
            starfieldPipeline: starfieldPipeline!,
            horizonPipeline: horizonPipeline!,
            sceneModelPipeline: sceneModelPipeline!,
            modelTilePipeline: modelTilePipeline!,
            treePipeline: treePipeline!,
            layerPipeline: layerPipeline!,
            placementStencilPipeline: placementStencilPipeline!,
            globeCap: globeCap!,
            avatars: avatars!,
            textRenderer: textRenderer!
        )
    }

    // MARK: - Shadow fallback

    /// One lit texel for the ground pipeline's mask slot on frames without
    /// the mask pass. A color texture, so it can be filled from the CPU.
    private nonisolated static func makeGroundShadowMaskFallbackTexture(device: MTLDevice) -> MTLTexture {
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

    private nonisolated static func makeShadowFallbackTexture(device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = ShadowCascadeAtlas.sliceCount
        descriptor.pixelFormat = ShadowCascadeAtlas.depthPixelFormat
        descriptor.width = 1
        descriptor.height = 1
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        texture.label = "ShadowFallbackTexture"

        // A throwaway queue: the clears run once per process, before any
        // view samples the texture. One plain pass per slice, never a
        // layered pass, which the iOS Simulator does not implement.
        guard let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer() else {
            return texture
        }
        for slice in 0..<ShadowCascadeAtlas.sliceCount {
            let passDescriptor = makeShadowFallbackClearDescriptor(texture: texture, slice: slice)
            commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)?.endEncoding()
        }
        commandBuffer.commit()
        return texture
    }

    /// One texel of depth at the far plane for the road labels' scene depth
    /// slot on frames without a kept scene depth: a plain 2D depth texture,
    /// as the shader's `depth2d` wants, cleared by the same no-draw pass.
    private nonisolated static func makeSceneDepthFallbackTexture(device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = ShadowCascadeAtlas.depthPixelFormat
        descriptor.width = 1
        descriptor.height = 1
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        texture.label = "SceneDepthFallbackTexture"
        guard let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer() else {
            return texture
        }
        let passDescriptor = makeShadowFallbackClearDescriptor(texture: texture)
        commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)?.endEncoding()
        commandBuffer.commit()
        return texture
    }

    /// The no-draw pass that leaves one slice of the fallback texture
    /// cleared to the far plane. Every receiver samples this texture while
    /// shadows are off, so it has to arrive cleared.
    nonisolated static func makeShadowFallbackClearDescriptor(texture: MTLTexture, slice: Int = 0) -> MTLRenderPassDescriptor {
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.depthAttachment.texture = texture
        passDescriptor.depthAttachment.slice = slice
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.storeAction = .store
        passDescriptor.depthAttachment.clearDepth = 1.0
        return passDescriptor
    }

    // MARK: - Depth descriptors

    private nonisolated static func makeSceneDepthDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true
        return descriptor
    }

    private nonisolated static func makeGlobeCapDepthDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }

    private nonisolated static func makeSkyBackdropDepthDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }

    /// The horizon layer's ground side: a far-plane fragment (z = 1) passes
    /// the greater test exactly where a nearer depth was written, which is
    /// every painted pixel, and fails on the cleared depth of the sky.
    private nonisolated static func makeHorizonGroundDepthDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .greater
        descriptor.isDepthWriteEnabled = false
        // And not where a standing surface raised the mask bit: the haze is
        // the ground's, and a wall crossing the horizon row keeps its own
        // colour. Reference 0 through a mask of the bit alone.
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .equal
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        stencil.depthStencilPassOperation = .keep
        stencil.readMask = TileSourceStencilPriority.surfaceMaskBit
        stencil.writeMask = 0
        descriptor.frontFaceStencil = stencil
        descriptor.backFaceStencil = stencil
        return descriptor
    }

    private nonisolated static func makeGroundDepthDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .less
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }

    /// The tile-priority stencil (TileSourceStencilPriority): the stencil
    /// holds the planner's decision, written by the placement prepass, and
    /// every tile pass tests `equal` to its source's zoom and writes
    /// nothing: a source paints the ground it was given and no other.
    /// `opaque` is the pass that lays a source's ground: it reads the
    /// priority bits alone, under the surface mask bit the buildings and
    /// the models raise, which no tile pass clears. Every other pass reads
    /// the mask bit too: a pixel a building or a model stands on carries
    /// it, which puts the value past any reference, so the ribbons, the
    /// roads and the translucent fills never paint over them, whatever
    /// the depth says over a relief, where a road biased off the ground
    /// would.
    private nonisolated static func makeTilePriorityStencil(opaque: Bool) -> MTLStencilDescriptor {
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .equal
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        stencil.depthStencilPassOperation = .keep
        stencil.readMask = opaque
            ? TileSourceStencilPriority.priorityMask
            : TileSourceStencilPriority.priorityMask | TileSourceStencilPriority.surfaceMaskBit
        stencil.writeMask = 0
        return stencil
    }

    /// The surface mask (TileSourceStencilPriority.surfaceMaskBit): a
    /// standing surface raises the bit wherever it passes both tests, and
    /// nothing else in the stencil changes.
    private nonisolated static func makeSurfaceMaskWrite(compare: MTLCompareFunction) -> MTLStencilDescriptor {
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = compare
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        stencil.depthStencilPassOperation = .replace
        stencil.readMask = TileSourceStencilPriority.priorityMask
        stencil.writeMask = TileSourceStencilPriority.surfaceMaskBit
        return stencil
    }

    /// The sphere's opaque ground pass: the layer-rank depth (lessEqual,
    /// written) under the tile-priority test.
    private nonisolated static func makeSphereOpaqueOwnerDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = makeSceneDepthDescriptor()
        descriptor.frontFaceStencil = makeTilePriorityStencil(opaque: true)
        descriptor.backFaceStencil = makeTilePriorityStencil(opaque: true)
        return descriptor
    }

    /// The sphere's ribbon cores (TilePipeline.SphereRibbonPhase.core):
    /// the rank depth written under a strict test, drawn highest rank
    /// first, so a pixel several strokes cover blends once, by the highest
    /// of them, and a second piece of the same stroke, at the same rank,
    /// is rejected where the first already painted. Under the tile-priority
    /// test with the surface mask, as every non-owning pass.
    private nonisolated static func makeSphereRibbonOwnerDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .less
        descriptor.isDepthWriteEnabled = true
        descriptor.frontFaceStencil = makeTilePriorityStencil(opaque: false)
        descriptor.backFaceStencil = makeTilePriorityStencil(opaque: false)
        return descriptor
    }

    /// The flat ground's opaque pass: the ground depth test (against the
    /// buildings), WRITING the rank band so a pixel is shaded once by its
    /// topmost opaque layer, under the tile-priority test: a source
    /// paints the ground it was given and no other, whatever the depth
    /// says there, so the sources never meet by depth. The depth test is
    /// lessEqual for a source's own layers, which stack at the band's
    /// steps, and a vector tile over a raster of the same source (its
    /// lines) lies nearer by half a step (TileRaster.metal).
    private nonisolated static func makeGroundOwnerDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = makeGroundDepthDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true
        descriptor.frontFaceStencil = makeTilePriorityStencil(opaque: true)
        descriptor.backFaceStencil = makeTilePriorityStencil(opaque: true)
        return descriptor
    }

    /// The flat road buckets: the ground depth test against the ranks
    /// (`RoadRankDepth`), WRITING the rank, on the road's source's own
    /// ground (the tile-priority test). A fragment passes only where it is
    /// nearer than what is there, so an opaque road is shaded once per
    /// pixel by its highest rank, and a road that blends lands once per
    /// pixel of a rank, an equal rank failing.
    private nonisolated static func makeRoadRankDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = makeGroundDepthDescriptor()
        descriptor.isDepthWriteEnabled = true
        descriptor.frontFaceStencil = makeTilePriorityStencil(opaque: false)
        descriptor.backFaceStencil = makeTilePriorityStencil(opaque: false)
        return descriptor
    }

    /// The non-owning tile passes of either surface (translucent fills,
    /// ribbons, the flat road edge lines and the bridge overlay): the
    /// ground depth test plus the tile-priority test, no writes.
    private nonisolated static func makeTileStencilTestDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = makeGroundDepthDescriptor()
        descriptor.frontFaceStencil = makeTilePriorityStencil(opaque: false)
        descriptor.backFaceStencil = makeTilePriorityStencil(opaque: false)
        return descriptor
    }

    /// The placement prepass on the plane and the sphere: the depth always
    /// passes and is never written, so a placement's mark lands on every
    /// pixel of its square, through the priority bits alone
    /// (`TileSourceStencilPriority`).
    private nonisolated static func makePlacementStencilWriteDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = makeDepthDisabledDescriptor()
        descriptor.frontFaceStencil = makePlacementMarkStencil()
        descriptor.backFaceStencil = makePlacementMarkStencil()
        return descriptor
    }

    /// The relief's first prepass: the ground's depth, every point of it
    /// once, the nearer of two surfaces kept, the stencil untouched.
    private nonisolated static func makePlacementDepthWriteDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true
        return descriptor
    }

    /// The relief's marks: a placement's mark lands where its ground is
    /// the one in front, at or before the ground's depth, and the depth
    /// is left as it is.
    private nonisolated static func makePlacementStencilReliefWriteDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = false
        descriptor.frontFaceStencil = makePlacementMarkStencil()
        descriptor.backFaceStencil = makePlacementMarkStencil()
        return descriptor
    }

    /// The relief's depth reset: the far plane written over every pixel,
    /// the stencil untouched, so the ground passes meet the cleared depth.
    private nonisolated static func makePlacementDepthResetDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = true
        return descriptor
    }

    private nonisolated static func makePlacementMarkStencil() -> MTLStencilDescriptor {
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .always
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        stencil.depthStencilPassOperation = .replace
        stencil.readMask = 0
        stencil.writeMask = TileSourceStencilPriority.priorityMask
        return stencil
    }

    /// The world-pass buildings: scene depth for their own occlusion and
    /// nothing else to test. The building coverage is a partition of the
    /// ground (`BuildingCoveragePlanner`), so no two tiles draw a building
    /// over the same ground and the tile-priority test is not needed; a
    /// wall rises into the pixels of the ground behind it, where that test
    /// would compare it against the wrong tile anyway. The surface mask bit
    /// is still raised where a building lands, for the horizon.
    private nonisolated static func makeExtrudedStencilTestDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = makeSceneDepthDescriptor()
        descriptor.frontFaceStencil = makeSurfaceMaskWrite(compare: .always)
        descriptor.backFaceStencil = makeSurfaceMaskWrite(compare: .always)
        return descriptor
    }

    /// The world-pass scene models: scene depth, no priority test (a model
    /// belongs to no tile), and the surface mask bit raised where it lands.
    private nonisolated static func makeSceneModelSurfaceMaskDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = makeSceneDepthDescriptor()
        descriptor.frontFaceStencil = makeSurfaceMaskWrite(compare: .always)
        descriptor.backFaceStencil = makeSurfaceMaskWrite(compare: .always)
        return descriptor
    }

    /// The ground hole's footprint draws (SceneModel.metal): depth neither
    /// tested nor written, the ground hole bit raised on every pixel of the
    /// flattened outline, or lowered again after the model.
    private nonisolated static func makeSceneModelGroundHoleDescriptor(raises: Bool) -> MTLDepthStencilDescriptor {
        let descriptor = makeDepthDisabledDescriptor()
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .always
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        // Replace writes the reference, which is the bit, through the mask;
        // zero clears the bit through the same mask.
        stencil.depthStencilPassOperation = raises ? .replace : .zero
        stencil.readMask = 0
        stencil.writeMask = TileSourceStencilPriority.groundHoleBit
        descriptor.frontFaceStencil = stencil
        descriptor.backFaceStencil = stencil
        return descriptor
    }

    /// The two model draws of the ground cut: scene depth, the surface mask
    /// bit raised where the model lands, and the ground hole bit tested
    /// alone, equal to the reference's bit, which the drawer sets raised for
    /// the draw inside the hole and clear for the draw outside it.
    private nonisolated static func makeSceneModelGroundHoleTestDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = makeSceneDepthDescriptor()
        let stencil = makeSurfaceMaskWrite(compare: .equal)
        stencil.readMask = TileSourceStencilPriority.groundHoleBit
        descriptor.frontFaceStencil = stencil
        descriptor.backFaceStencil = stencil
        return descriptor
    }

    private nonisolated static func makeDepthDisabledDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }
}

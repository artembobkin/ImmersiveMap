// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

final class SceneModelRenderSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "SceneModels"

    private let sceneModelSource: SceneModelRenderSource
    private let meshStore: SceneModelMeshStore
    private let pipeline: SceneModelPipeline
    private let extrudedDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let shadowMapTextureProvider: () -> MTLTexture?
    private let shadowFallbackTexture: MTLTexture
    private let supportsFramebufferFetch: Bool
    private let presentationStateStore = SceneModelPresentationStateStore()
    private var drawItems: [SceneModelDrawItem] = []
    private var shadowCasterItems: [SceneModelDrawItem] = []

    init(sceneModelSource: SceneModelRenderSource,
         meshStore: SceneModelMeshStore,
         pipeline: SceneModelPipeline,
         extrudedDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         shadowMapTextureProvider: @escaping () -> MTLTexture?,
         shadowFallbackTexture: MTLTexture,
         supportsFramebufferFetch: Bool) {
        self.sceneModelSource = sceneModelSource
        self.meshStore = meshStore
        self.pipeline = pipeline
        self.extrudedDepthState = extrudedDepthState
        self.depthDisabledState = depthDisabledState
        self.shadowMapTextureProvider = shadowMapTextureProvider
        self.shadowFallbackTexture = shadowFallbackTexture
        self.supportsFramebufferFetch = supportsFramebufferFetch
    }

    func update(frameContext: FrameContext) {
        if let controller = sceneModelSource.currentSceneModelsController {
            if let snapshot = controller.consumeSnapshot() {
                presentationStateStore.apply(snapshot: snapshot, time: frameContext.time)
            }
        } else if presentationStateStore.isEmpty == false {
            // A detached controller leaves no snapshot source: clear instead of
            // rendering stale models forever.
            presentationStateStore.apply(snapshot: SceneModelsSnapshot(models: [],
                                                                       transformAnimationDurationsById: [:],
                                                                       removedIds: [],
                                                                       version: 0),
                                         time: frameContext.time)
        }

        let presented = presentationStateStore.presentedEntries(at: frameContext.time)
        frameContext.sharedState.sceneModelState.hasActiveAnimations = presentationStateStore.hasActiveAnimations
        frameContext.sharedState.sceneModelState.hasShadowCasters = false
        // Cleared up front so every early return below leaves an empty
        // snapshot: a model that stops being drawn must stop being tappable.
        frameContext.sharedState.sceneModelState.selectionSnapshot = .empty
        frameContext.sharedState.sceneModelState.pathAnimationResults =
            presentationStateStore.consumePathAnimationResults()

        guard presented.isEmpty == false else {
            drawItems = []
            shadowCasterItems = []
            _ = meshStore.requestMeshes(for: [])
            return
        }

        let readyMeshes = meshStore.requestMeshes(for: Set(presented.map(\.source.url)))
        guard readyMeshes.isEmpty == false else {
            drawItems = []
            shadowCasterItems = []
            return
        }

        let constants = GeoScreenProjectionMath.FrameConstants(drawSize: frameContext.drawSize,
                                                               cameraUniform: frameContext.cameraUniform,
                                                               resolvedPresentation: frameContext.resolvedPresentation)
        let frustum = Frustum(pv: frameContext.cameraMatrices.projectionView)
        // The shadow pass culls with the LIGHT frustum and without the horizon
        // gate: a model outside the camera view still casts into it. The far
        // cascade's volume is a superset of the near one, so one cull suffices
        // (the near viewport's scissor drops the excess).
        let shadowFrustum = frameContext.shadowFrameState.flatMap { state in
            state.lightProjectionViews.last.map { Frustum(pv: $0) }
        }
        var items: [SceneModelDrawItem] = []
        var shadowItems: [SceneModelDrawItem] = []
        var selectionEntries: [SceneModelSelectionEntry] = []
        items.reserveCapacity(presented.count)
        for model in presented {
            guard let mesh = readyMeshes[model.source.url] else { continue }
            let anchor = SceneModelAnchorMath.resolveAnchor(presented: model,
                                                            bounds: mesh.localBounds,
                                                            constants: constants)
            guard anchor.boundingSphereRadius > 0 else { continue }

            if let shadowFrustum,
               shadowFrustum.isSphereVisible(center: anchor.boundingSphereCenter,
                                             radius: anchor.boundingSphereRadius) {
                shadowItems.append(SceneModelDrawItem(mesh: mesh, modelMatrix: anchor.modelMatrix))
            }

            guard anchor.passesHorizonGate,
                  frustum.isSphereVisible(center: anchor.boundingSphereCenter,
                                          radius: anchor.boundingSphereRadius) else {
                continue
            }
            items.append(SceneModelDrawItem(mesh: mesh, modelMatrix: anchor.modelMatrix))
            // Built from the drawn item, not from the presented list: the hit
            // volume is the geometry this frame put on screen, so the horizon
            // gate and the frustum cull it exactly as they cull the draw.
            selectionEntries.append(SceneModelSelectionEntry(id: model.id,
                                                             coordinate: model.coordinate,
                                                             modelMatrix: anchor.modelMatrix,
                                                             boundsMin: mesh.localBounds.minimum,
                                                             boundsMax: mesh.localBounds.maximum))
        }
        drawItems = items
        shadowCasterItems = shadowItems
        frameContext.sharedState.sceneModelState.hasShadowCasters = shadowItems.isEmpty == false
        frameContext.sharedState.sceneModelState.selectionSnapshot = SceneModelSelectionSnapshot(
            frameIndex: frameContext.frameIndex,
            drawSize: frameContext.drawSize,
            projectionView: frameContext.cameraMatrices.projectionView,
            cameraEye: frameContext.cameraEye,
            entries: selectionEntries)
    }

    func contributePassAvailability(settings _: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.sceneModelOcclusionEnabled = builder.sceneModelOcclusionEnabled
            || drawItems.isEmpty == false
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        switch layer {
        case .sceneModels:
            guard drawItems.isEmpty == false else { return }
            let shadowBinding = ShadowReceiverBinding.resolve(frameContext: frameContext,
                                                              shadowMapTexture: shadowMapTextureProvider(),
                                                              fallbackTexture: shadowFallbackTexture)
            // The framebuffer-fetch world pass carries a second building
            // attachment; every pipeline in it must declare that attachment
            // to stay pass-compatible (same decision as RenderPassGraph.plan).
            let withBuildingImageAttachment = BuildingExtrusionPathResolver.usesInPassBuildingImage(
                style: frameContext.services.settings.style,
                zoom: frameContext.zoom,
                renderSurfaceMode: frameContext.renderSurfaceMode,
                supportsFramebufferFetch: supportsFramebufferFetch
            )
            SceneModelDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  shadowBinding: shadowBinding,
                                  items: drawItems,
                                  pipeline: pipeline,
                                  extrudedDepthState: extrudedDepthState,
                                  depthDisabledState: depthDisabledState,
                                  withBuildingImageAttachment: withBuildingImageAttachment)
        case .sceneModelOcclusion:
            guard drawItems.isEmpty == false else { return }
            SceneModelDrawer.drawLabelOcclusion(renderEncoder: encoder,
                                                cameraUniform: frameContext.cameraUniform,
                                                items: drawItems,
                                                pipeline: pipeline,
                                                extrudedDepthState: extrudedDepthState,
                                                depthDisabledState: depthDisabledState)
        case .shadowCasters:
            guard let shadowState = frameContext.shadowFrameState,
                  shadowCasterItems.isEmpty == false else { return }
            SceneModelDrawer.drawShadowCasters(renderEncoder: encoder,
                                               lightProjectionViews: shadowState.lightProjectionViews,
                                               items: shadowCasterItems,
                                               pipeline: pipeline,
                                               extrudedDepthState: extrudedDepthState)
        default:
            return
        }
    }

    func handleMemoryWarning() {
        meshStore.handleMemoryWarning()
    }

    func evict() {
        meshStore.evict()
    }
}

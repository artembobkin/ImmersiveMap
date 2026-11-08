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
    /// World-pass draws: scene depth plus the surface mask bit, so the
    /// horizon's haze passes the models by.
    private let surfaceMaskState: MTLDepthStencilState
    /// The ground cut's draws for the models that cut into the ground.
    private let groundCutStates: SceneModelGroundCutStates
    private let depthDisabledState: MTLDepthStencilState
    private let shadowMapTextureProvider: () -> MTLTexture?
    private let shadowFallbackTexture: MTLTexture
    private let presentationStateStore = SceneModelPresentationStateStore()
    private var drawItems: [SceneModelDrawItem] = []
    private var shadowCasterItems: [SceneModelDrawItem] = []

    init(sceneModelSource: SceneModelRenderSource,
         meshStore: SceneModelMeshStore,
         pipeline: SceneModelPipeline,
         extrudedDepthState: MTLDepthStencilState,
         surfaceMaskState: MTLDepthStencilState,
         groundCutStates: SceneModelGroundCutStates,
         depthDisabledState: MTLDepthStencilState,
         shadowMapTextureProvider: @escaping () -> MTLTexture?,
         shadowFallbackTexture: MTLTexture) {
        self.sceneModelSource = sceneModelSource
        self.meshStore = meshStore
        self.pipeline = pipeline
        self.extrudedDepthState = extrudedDepthState
        self.surfaceMaskState = surfaceMaskState
        self.groundCutStates = groundCutStates
        self.depthDisabledState = depthDisabledState
        self.shadowMapTextureProvider = shadowMapTextureProvider
        self.shadowFallbackTexture = shadowFallbackTexture
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
        frameContext.sharedState.sceneModelState.hasMovingShadowCasters = false
        frameContext.sharedState.sceneModelState.staticShadowCasters = []
        // The frame's replaced buildings start empty: the model tiles add
        // theirs (`ModelTileRenderSubsystem`).
        frameContext.sharedState.sceneModelState.replacedBuildings = .none
        frameContext.sharedState.sceneModelState.hasDrawnModels = false
        // Cleared up front so every early return below leaves an empty
        // snapshot: a model that stops being drawn must stop being tappable.
        frameContext.sharedState.sceneModelState.selectionSnapshot = .empty
        frameContext.sharedState.sceneModelState.pathAnimationResults =
            presentationStateStore.consumePathAnimationResults()

        guard presented.isEmpty == false else {
            drawItems = []
            shadowCasterItems = []
            _ = meshStore.requestMeshes(for: [])
            frameContext.services.diagnostics.setCounter(.pendingSceneModelMeshes, value: 0)
            return
        }

        let requestedURLs = Set(presented.map(\.source.url))
        let readyMeshes = meshStore.requestMeshes(for: requestedURLs)
        frameContext.services.diagnostics.setCounter(.pendingSceneModelMeshes,
                                                     value: requestedURLs.count - readyMeshes.count)
        guard readyMeshes.isEmpty == false else {
            drawItems = []
            shadowCasterItems = []
            return
        }

        let constants = GeoScreenProjectionMath.FrameConstants(drawSize: frameContext.drawSize,
                                                               cameraUniform: frameContext.cameraUniform,
                                                               resolvedPresentation: frameContext.resolvedPresentation)
        let frustum = Frustum(pv: frameContext.cameraMatrices.projectionView)
        // The shadow passes cull with the LIGHT frustum (the far window's,
        // which holds the near one) and without the horizon gate: a model
        // outside the camera view still casts into it.
        let shadowFrustum = frameContext.shadowFrameState.map { state in
            Frustum(pv: state.casterCullingProjectionView)
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
                shadowItems.append(SceneModelDrawItem(mesh: mesh,
                                                      modelMatrix: anchor.modelMatrix,
                                                      groundPlane: anchor.groundPlane,
                                                      cutsIntoGround: model.cutsIntoGround))
            }

            guard anchor.passesHorizonGate,
                  frustum.isSphereVisible(center: anchor.boundingSphereCenter,
                                          radius: anchor.boundingSphereRadius) else {
                continue
            }
            items.append(SceneModelDrawItem(mesh: mesh,
                                            modelMatrix: anchor.modelMatrix,
                                            groundPlane: anchor.groundPlane,
                                            cutsIntoGround: model.cutsIntoGround))
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
        frameContext.sharedState.sceneModelState.hasMovingShadowCasters = shadowItems.isEmpty == false
        frameContext.sharedState.sceneModelState.hasDrawnModels = items.isEmpty == false
        frameContext.sharedState.sceneModelState.selectionSnapshot = SceneModelSelectionSnapshot(
            frameIndex: frameContext.frameIndex,
            drawSize: frameContext.drawSize,
            projectionView: frameContext.cameraMatrices.projectionView,
            cameraEye: frameContext.cameraEye,
            entries: selectionEntries)
    }

    func contributePassAvailability(settings _: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        let hasDrawItems = drawItems.isEmpty == false
        builder.sceneModelsEnabled = builder.sceneModelsEnabled || hasDrawItems
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        switch layer {
        case .sceneModels:
            guard drawItems.isEmpty == false else { return }
            let shadowBinding = ShadowReceiverBinding.resolve(frameContext: frameContext,
                                                              shadowMapTexture: shadowMapTextureProvider(),
                                                              fallbackTexture: shadowFallbackTexture)
            GroundFogUniform.bind(GroundFogUniform.resolveForBuildings(frameContext: frameContext), encoder: encoder)
            SceneModelDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  shadowBinding: shadowBinding,
                                  items: drawItems,
                                  pipeline: pipeline,
                                  surfaceMaskState: surfaceMaskState,
                                  groundCutStates: groundCutStates,
                                  depthDisabledState: depthDisabledState)
        case .shadowCasters, .farShadowCasters:
            guard let slot = ShadowCascadeSlot(casterLayer: layer),
                  let lightProjectionView = frameContext.shadowFrameState?.lightProjectionView(for: slot),
                  shadowCasterItems.isEmpty == false else { return }
            SceneModelDrawer.drawShadowCasters(renderEncoder: encoder,
                                               lightProjectionView: lightProjectionView,
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

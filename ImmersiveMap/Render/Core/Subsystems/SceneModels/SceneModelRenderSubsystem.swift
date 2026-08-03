// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

final class SceneModelRenderSubsystem: RenderSubsystem {
    let name: String = "SceneModels"

    private let sceneModelSource: SceneModelRenderSource
    private let meshStore: SceneModelMeshStore
    private let pipeline: SceneModelPipeline
    private let extrudedDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let presentationStateStore = SceneModelPresentationStateStore()
    private var drawItems: [SceneModelDrawItem] = []

    init(sceneModelSource: SceneModelRenderSource,
         meshStore: SceneModelMeshStore,
         pipeline: SceneModelPipeline,
         extrudedDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState) {
        self.sceneModelSource = sceneModelSource
        self.meshStore = meshStore
        self.pipeline = pipeline
        self.extrudedDepthState = extrudedDepthState
        self.depthDisabledState = depthDisabledState
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

        guard presented.isEmpty == false else {
            drawItems = []
            _ = meshStore.requestMeshes(for: [])
            return
        }

        let readyMeshes = meshStore.requestMeshes(for: Set(presented.map(\.source.url)))
        guard readyMeshes.isEmpty == false else {
            drawItems = []
            return
        }

        let constants = GeoScreenProjectionMath.FrameConstants(drawSize: frameContext.drawSize,
                                                               cameraUniform: frameContext.cameraUniform,
                                                               resolvedPresentation: frameContext.resolvedPresentation)
        let frustum = Frustum(pv: frameContext.cameraMatrices.projectionView)
        var items: [SceneModelDrawItem] = []
        items.reserveCapacity(presented.count)
        for model in presented {
            guard let mesh = readyMeshes[model.source.url] else { continue }
            let anchor = SceneModelAnchorMath.resolveAnchor(presented: model,
                                                            bounds: mesh.localBounds,
                                                            constants: constants)
            guard anchor.passesHorizonGate,
                  anchor.boundingSphereRadius > 0,
                  frustum.isSphereVisible(center: anchor.boundingSphereCenter,
                                          radius: anchor.boundingSphereRadius) else {
                continue
            }
            items.append(SceneModelDrawItem(mesh: mesh, modelMatrix: anchor.modelMatrix))
        }
        drawItems = items
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .sceneModels, drawItems.isEmpty == false else { return }
        SceneModelDrawer.draw(renderEncoder: encoder,
                              cameraUniform: frameContext.cameraUniform,
                              items: drawItems,
                              pipeline: pipeline,
                              extrudedDepthState: extrudedDepthState,
                              depthDisabledState: depthDisabledState)
    }

    func handleMemoryWarning() {
        meshStore.handleMemoryWarning()
    }

    func evict() {
        meshStore.evict()
    }
}

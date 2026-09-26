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
    private let depthDisabledState: MTLDepthStencilState
    private let shadowMapTextureProvider: () -> MTLTexture?
    private let shadowFallbackTexture: MTLTexture
    private let presentationStateStore = SceneModelPresentationStateStore()
    /// The landmarks' models, kept apart from the app's scene models: their
    /// ids are the landmarks' positions in the settings, so they never meet
    /// the controller's ids, and they draw but are not tappable.
    private let landmarkStateStore = SceneModelPresentationStateStore()
    private var appliedLandmarks: [ImmersiveMapLandmark] = []
    private var landmarkSnapshotVersion: UInt64 = 0
    private var drawItems: [SceneModelDrawItem] = []
    private var shadowCasterItems: [SceneModelDrawItem] = []

    init(sceneModelSource: SceneModelRenderSource,
         meshStore: SceneModelMeshStore,
         pipeline: SceneModelPipeline,
         extrudedDepthState: MTLDepthStencilState,
         surfaceMaskState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         shadowMapTextureProvider: @escaping () -> MTLTexture?,
         shadowFallbackTexture: MTLTexture) {
        self.sceneModelSource = sceneModelSource
        self.meshStore = meshStore
        self.pipeline = pipeline
        self.extrudedDepthState = extrudedDepthState
        self.surfaceMaskState = surfaceMaskState
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

        applyLandmarks(frameContext.services.settings.landmarks, time: frameContext.time)

        // The app's models first, the landmarks after them: the index
        // tells a landmark apart below.
        let presentedSceneModels = presentationStateStore.presentedEntries(at: frameContext.time)
        let presented = presentedSceneModels + presentedLandmarks(frameContext: frameContext)
        frameContext.sharedState.sceneModelState.hasActiveAnimations = presentationStateStore.hasActiveAnimations
        frameContext.sharedState.sceneModelState.hasShadowCasters = false
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
        // The shadow pass culls with the LIGHT frustum and without the horizon
        // gate: a model outside the camera view still casts into it.
        let shadowFrustum = frameContext.shadowFrameState.map { state in
            Frustum(pv: state.lightProjectionView)
        }
        var items: [SceneModelDrawItem] = []
        var shadowItems: [SceneModelDrawItem] = []
        var selectionEntries: [SceneModelSelectionEntry] = []
        items.reserveCapacity(presented.count)
        let landmarkStartIndex = presentedSceneModels.count
        for (index, model) in presented.enumerated() {
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
            // A landmark draws but is not tappable: it stands for a building.
            guard index < landmarkStartIndex else { continue }
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
        frameContext.sharedState.sceneModelState.hasDrawnModels = items.isEmpty == false
        frameContext.sharedState.sceneModelState.selectionSnapshot = SceneModelSelectionSnapshot(
            frameIndex: frameContext.frameIndex,
            drawSize: frameContext.drawSize,
            projectionView: frameContext.cameraMatrices.projectionView,
            cameraEye: frameContext.cameraEye,
            entries: selectionEntries)
    }

    /// The landmarks drawn at this zoom: one below its `minimumZoom` is left
    /// out, and the tiles of that zoom still carry the map's building. The
    /// zoom compared is the tile zoom the frame draws, the same one the
    /// tiles decide by, so the model and the building never both show or
    /// both go missing. The store's entries are the landmarks in settings
    /// order: their ids are the positions.
    private func presentedLandmarks(frameContext: FrameContext) -> [PresentedSceneModel] {
        let entries = landmarkStateStore.presentedEntries(at: frameContext.time)
        let maximumTileZoom = frameContext.services.settings.tiles.coverage.maximumZoomLevel
        let tileZoom = min(max(0, frameContext.zoomLevel), maximumTileZoom)
        return entries.filter { entry in
            let index = Int(entry.id)
            guard index < appliedLandmarks.count else { return false }
            return tileZoom >= appliedLandmarks[index].effectiveMinimumZoom(maximumTileZoom: maximumTileZoom)
        }
    }

    /// Feeds the landmarks from the settings into their own store when they
    /// change: the whole list replaces the last one, and a model snaps to its
    /// new transform.
    private func applyLandmarks(_ landmarks: [ImmersiveMapLandmark], time: TimeInterval) {
        guard landmarks != appliedLandmarks else { return }
        let models = landmarks.enumerated().map { index, landmark in
            ImmersiveMapSceneModel(id: UInt64(index),
                                   source: landmark.model,
                                   coordinate: landmark.coordinate,
                                   headingDegrees: landmark.headingDegrees,
                                   scale: landmark.scale)
        }
        let removedIds = (landmarks.count..<max(landmarks.count, appliedLandmarks.count)).map { UInt64($0) }
        landmarkSnapshotVersion &+= 1
        landmarkStateStore.apply(snapshot: SceneModelsSnapshot(models: models,
                                                               transformAnimationDurationsById: [:],
                                                               removedIds: removedIds,
                                                               version: landmarkSnapshotVersion),
                                 time: time)
        appliedLandmarks = landmarks
    }

    func contributePassAvailability(settings _: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        let hasDrawItems = drawItems.isEmpty == false
        builder.sceneModelsEnabled = builder.sceneModelsEnabled || hasDrawItems
        builder.sceneModelOcclusionEnabled = builder.sceneModelOcclusionEnabled || hasDrawItems
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        switch layer {
        case .sceneModels:
            guard drawItems.isEmpty == false else { return }
            let shadowBinding = ShadowReceiverBinding.resolve(frameContext: frameContext,
                                                              shadowMapTexture: shadowMapTextureProvider(),
                                                              fallbackTexture: shadowFallbackTexture)
            SceneModelDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  shadowBinding: shadowBinding,
                                  items: drawItems,
                                  pipeline: pipeline,
                                  surfaceMaskState: surfaceMaskState,
                                  depthDisabledState: depthDisabledState)
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
                                               lightProjectionView: shadowState.lightProjectionView,
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

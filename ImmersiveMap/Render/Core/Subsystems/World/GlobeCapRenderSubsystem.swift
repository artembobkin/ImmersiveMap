// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The polar caps: the sphere beyond the Mercator edge, drawn after the tile
/// geometry with the rim colour the tiles show at that edge. That colour is
/// baked into an edge strip per pole (`GlobeCapEdgeStrip`) whenever what the
/// pole rows would draw changes: the placements, or any of the zoom-continuous
/// inputs of the ground shading (the fades, the palette handover, the width
/// taper). The bake is two passes over one texel row each, so re-baking per
/// frame while a fade moves costs nothing worth avoiding.
final class GlobeCapRenderSubsystem: RenderSubsystem {
    let name: String = "GlobeCap"

    private let globeCapDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let globeCapRenderer: GlobeCapRenderer
    private let edgeStrip: GlobeCapEdgeStrip

    private var stripTracker = StagedHashChangeTracker()
    private var hasStrip = false
    private var pendingPlacements: [PlaceTile] = []
    private var pendingParameters: GlobeCapEdgeStrip.BakeParameters?
    private var poleMeanLod: [GlobeCapPole: Float] = [:]

    init(globeCapDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         globeCapRenderer: GlobeCapRenderer,
         edgeStrip: GlobeCapEdgeStrip) {
        self.globeCapDepthState = globeCapDepthState
        self.depthDisabledState = depthDisabledState
        self.globeCapRenderer = globeCapRenderer
        self.edgeStrip = edgeStrip
    }

    func update(frameContext: FrameContext) {
        guard frameContext.renderSurfaceMode == .spherical else {
            return
        }
        let placementState = frameContext.sharedState.tilePlacementState
        let placements = placementState.placeTilesContext.tilePlacements
        let zoom = frameContext.zoom
        let pixelsPerPoint = Float(frameContext.pixelsPerPoint)
        let mapClearColor = frameContext.services.settings.scene.mapClearColor
        let parameters = GlobeCapEdgeStrip.BakeParameters(
            clearColor: SIMD4<Float>(Float(mapClearColor.x), Float(mapClearColor.y),
                                     Float(mapClearColor.z), Float(mapClearColor.w)),
            overviewFade: TileOverviewFadeUniform(
                overviewAlpha: LowZoomOverviewFade.alpha(for: zoom, kind: .overviewFeatures),
                roadAlpha: LowZoomOverviewFade.alpha(for: zoom, kind: .roads),
                landuseAlpha: LowZoomOverviewFade.alpha(for: zoom, kind: .landuse),
                pixelsPerPoint: pixelsPerPoint * LineWidthZoomTaper.scale(for: zoom),
                cameraZoom: Float(zoom)),
            streetPaletteBlend: LowZoomOverviewFade.streetPaletteBlend(for: zoom),
            dashPixelsPerPoint: pixelsPerPoint,
            drawableHeightPx: Float(frameContext.drawSize.height),
            renderMapSize: frameContext.resolvedPresentation.renderNormalizationState.flatRenderMapSize)

        var hasher = Hasher()
        hasher.combine(Int(truncatingIfNeeded: placementState.placementVersion))
        hasher.combine(parameters.overviewFade.overviewAlpha.bitPattern)
        hasher.combine(parameters.overviewFade.roadAlpha.bitPattern)
        hasher.combine(parameters.overviewFade.landuseAlpha.bitPattern)
        hasher.combine(parameters.overviewFade.pixelsPerPoint.bitPattern)
        hasher.combine(parameters.overviewFade.cameraZoom.bitPattern)
        hasher.combine(parameters.streetPaletteBlend.bitPattern)
        hasher.combine(parameters.drawableHeightPx.bitPattern)
        hasher.combine(parameters.clearColor.x.bitPattern)
        hasher.combine(parameters.clearColor.y.bitPattern)
        hasher.combine(parameters.clearColor.z.bitPattern)
        if stripTracker.stage(hasher.finalize()) {
            pendingPlacements = placements
            pendingParameters = parameters
        }

        for pole in GlobeCapPole.allCases {
            // The finest slot of the pole row sets the window of the pole
            // mean; with no placement in the row the previous value stands.
            let rowZoom = placements
                .filter { GlobeCapStripSampler.isPoleRow($0.placeIn.tile, pole: pole) }
                .map(\.placeIn.tile.z)
                .max()
            if let rowZoom {
                poleMeanLod[pole] = GlobeCapStripSampler.poleMeanLod(tileZoom: rowZoom)
            }
        }
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        guard frameContext.renderSurfaceMode == .spherical,
              stripTracker.hasPendingChange,
              let parameters = pendingParameters else {
            return
        }
        guard let commandBuffer = frameContext.commandBuffer else {
            frameContext.services.diagnostics.recordSkipReason(.missingCommandBuffer)
            return
        }
        for pole in GlobeCapPole.allCases {
            edgeStrip.bake(pole: pole,
                           placements: pendingPlacements,
                           parameters: parameters,
                           commandBuffer: commandBuffer)
        }
        hasStrip = true
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .globeCap,
              frameContext.renderSurfaceMode == .spherical else {
            return
        }

        encoder.setDepthStencilState(globeCapDepthState)
        globeCapRenderer.draw(renderEncoder: encoder,
                              cameraUniform: frameContext.cameraUniform,
                              globe: frameContext.globeRenderUniform,
                              earthScene: frameContext.earthSceneUniform,
                              atmosphere: GlobeAtmosphereUniform.make(settings: frameContext.services.settings.scene.atmosphere,
                                                                      earthScene: frameContext.earthSceneUniform,
                                                                      globe: frameContext.globeRenderUniform),
                              edgeStrip: edgeStrip,
                              stripUniform: { pole in
                                  GlobeCapStripUniform(hasStrip: self.hasStrip,
                                                       poleMeanLod: self.poleMeanLod[pole] ?? 0)
                              })

        encoder.setDepthStencilState(depthDisabledState)
    }

    // The strip hash is committed only after the command buffer commit(): a
    // frame dropped after prepareGPU never executes the bake, and the next
    // frame must encode it again.
    func frameCommitted() {
        stripTracker.commitPending()
    }

    func handleMemoryWarning() {
        invalidateStrip()
    }

    func evict() {
        invalidateStrip()
    }

    private func invalidateStrip() {
        stripTracker.invalidate()
        hasStrip = false
        pendingPlacements = []
        pendingParameters = nil
        poleMeanLod = [:]
    }
}

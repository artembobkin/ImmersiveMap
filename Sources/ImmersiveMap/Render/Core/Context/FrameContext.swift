// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  FrameContext.swift
//  ImmersiveMap
//

import CoreGraphics
import Foundation
import Metal
import QuartzCore
import simd

struct FrameContext {
    let frameIndex: UInt64
    let frameSlotIndex: Int
    let time: TimeInterval
    let deltaTime: TimeInterval
    let drawSize: CGSize
    /// Drawable pixels per layout point. Everything else in `Render` is
    /// pixel-native; this is the one conversion factor for style values the
    /// public API expresses in points.
    let pixelsPerPoint: CGFloat
    let viewport: SIMD2<Float>
    let cameraMatrices: FrameCameraMatrices
    let cameraEye: SIMD3<Float>
    let mapCameraState: ImmersiveMapCameraState
    let resolvedPresentation: ResolvedPresentationState
    let visibleContent: VisibleContentState
    let commandBuffer: MTLCommandBuffer?
    let services: FrameContextServices
    let sharedState: FrameContextSharedState
    let diagnostics: FrameDiagnostics
    /// Directional-shadow state of the frame; nil when shadows are off or the
    /// frame cannot cast (globe mode, degenerate light or footprint).
    let shadowFrameState: ShadowFrameState?
    /// The engine's shadow-map reuse controller: pass planning asks it once
    /// per frame whether the caster pass must run or the rendered map still
    /// serves (see ShadowMapReuseController).
    let shadowMapReuse: ShadowMapReuseController

    /// The matrix the GPU draws with: the CPU projection's clip z moved
    /// to the GPU far plane and scaled for the real geometry
    /// (`RenderCamera.gpuClipDepthAdjustment`), which the CPU's own
    /// matrices never carry.
    var cameraUniform: CameraUniform {
        CameraUniform(matrix: RenderCamera.gpuClipDepthAdjustment * cameraMatrices.projectionView,
                      eye: cameraEye,
                      padding: 0)
    }

    /// `pixelsPerPoint` in the form the label, marker and collision code takes
    /// it: the single conversion from the points a style is authored in to the
    /// pixels a frame is rasterized in.
    var screenScale: ScreenScale {
        ScreenScale(contentsScale: pixelsPerPoint)
    }

    var mapPresentationState: ImmersiveMapPresentationState {
        resolvedPresentation.presentationState
    }

    var renderSurfaceMode: ViewMode {
        resolvedPresentation.renderSurfaceMode
    }

    var screenSpaceProjectionMode: ScreenSpaceProjectionMode {
        resolvedPresentation.screenSpaceProjectionMode
    }

    var renderNormalizationState: RenderNormalizationState {
        resolvedPresentation.renderNormalizationState
    }

    var globeRenderState: GlobeRenderState {
        resolvedPresentation.globeRenderState
    }

    var flatRenderState: FlatRenderState {
        resolvedPresentation.flatRenderState
    }

    var globeRenderUniform: GlobeUniform {
        resolvedPresentation.globeRenderUniform
    }

    var transition: Float {
        resolvedPresentation.transition
    }

    /// The camera's zoom, the fact of the frame: what the camera's pose is
    /// read from. The tiles and the rings are planned by `planningZoom`,
    /// and what dresses the frame by the zoom reads `animatedZoom`.
    var zoom: Double {
        mapCameraState.zoom
    }

    /// The camera's zoom followed over time (`AnimatedZoom`): the zoom the
    /// ground fog, the styles' zoom fades, the labels' reach and the rest
    /// of the frame's dressing are read at, so a zoom that jumps in one
    /// frame dresses the frame over a few.
    let animatedZoom: Double
    /// The zoom the map is planned by (`CameraStateController.planningZoom`):
    /// the coverage's target tiles, the ring rules and the relief's
    /// thresholds read it. Over the terrain it stays where the last zoom
    /// set it while the camera's own follows the ground.
    let planningZoom: Double
    /// How the camera's last move over the terrain was settled, for the
    /// debug panel (`TerrainFollowReport`), nil off the terrain.
    let terrainFollowReport: TerrainFollowReport?

    var zoomLevel: Int {
        Int(mapCameraState.zoom)
    }

    init(frameIndex: UInt64,
         frameSlotIndex: Int = 0,
         time: TimeInterval,
         deltaTime: TimeInterval,
         drawSize: CGSize,
         pixelsPerPoint: CGFloat = 1,
         viewport: SIMD2<Float>,
         cameraMatrices: FrameCameraMatrices,
         cameraEye: SIMD3<Float>,
         commandBuffer: MTLCommandBuffer?,
         services: FrameContextServices,
         mapCameraState: ImmersiveMapCameraState = .default,
         animatedZoom: Double? = nil,
         planningZoom: Double? = nil,
         terrainFollowReport: TerrainFollowReport? = nil,
         resolvedPresentation: ResolvedPresentationState? = nil,
         visibleContent: VisibleContentState = .empty,
         sharedState: FrameContextSharedState = FrameContextSharedState(),
         shadowFrameState: ShadowFrameState? = nil,
         shadowMapReuse: ShadowMapReuseController = ShadowMapReuseController(),
         diagnostics: FrameDiagnostics) {
        let fallbackResolvedPresentation = resolvedPresentation ?? PresentationStateResolver.resolve(cameraState: mapCameraState,
                                                                                              settings: ImmersiveMapSettings.default.presentation,
                                                                                              forcedRenderSurfaceMode: nil)
        self.frameIndex = frameIndex
        self.frameSlotIndex = frameSlotIndex
        self.time = time
        self.deltaTime = deltaTime
        self.drawSize = drawSize
        self.pixelsPerPoint = pixelsPerPoint
        self.viewport = viewport
        self.cameraMatrices = cameraMatrices
        self.cameraEye = cameraEye
        self.mapCameraState = fallbackResolvedPresentation.semanticWorldState.cameraState
        self.animatedZoom = animatedZoom ?? fallbackResolvedPresentation.semanticWorldState.cameraState.zoom
        self.planningZoom = planningZoom ?? fallbackResolvedPresentation.semanticWorldState.cameraState.zoom
        self.terrainFollowReport = terrainFollowReport
        self.resolvedPresentation = fallbackResolvedPresentation
        self.visibleContent = visibleContent
        self.commandBuffer = commandBuffer
        self.services = services
        self.sharedState = sharedState
        self.shadowFrameState = shadowFrameState
        self.shadowMapReuse = shadowMapReuse
        self.diagnostics = diagnostics
    }
}

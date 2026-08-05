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
    let qualityTier: RenderQualityTier
    let commandBuffer: MTLCommandBuffer?
    let services: FrameContextServices
    let sharedState: FrameContextSharedState
    let diagnostics: FrameDiagnostics
    /// Directional-shadow state of the frame; nil when shadows are off or the
    /// frame cannot cast (globe mode, degenerate light or footprint).
    let shadowFrameState: ShadowFrameState?

    var cameraUniform: CameraUniform {
        CameraUniform(matrix: cameraMatrices.projectionView, eye: cameraEye, padding: 0)
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

    var earthSceneUniform: EarthSceneUniform {
        EarthSceneUniform(settings: services.settings.scene.earth, now: services.now, zoom: zoom)
    }

    var transition: Float {
        resolvedPresentation.transition
    }

    var zoom: Double {
        mapCameraState.zoom
    }

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
         qualityTier: RenderQualityTier,
         commandBuffer: MTLCommandBuffer?,
         services: FrameContextServices,
         mapCameraState: ImmersiveMapCameraState = .default,
         resolvedPresentation: ResolvedPresentationState? = nil,
         visibleContent: VisibleContentState = .empty,
         sharedState: FrameContextSharedState = FrameContextSharedState(),
         shadowFrameState: ShadowFrameState? = nil,
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
        self.resolvedPresentation = fallbackResolvedPresentation
        self.visibleContent = visibleContent
        self.qualityTier = qualityTier
        self.commandBuffer = commandBuffer
        self.services = services
        self.sharedState = sharedState
        self.shadowFrameState = shadowFrameState
        self.diagnostics = diagnostics
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Draws route ribbons in the world pass. Globe presentation only: the layer is
/// absent from the flat plan, and the ribbon fades out over the tail of the
/// unfurl so it does not pop when the surface mode flips.
final class RouteRenderSubsystem: RenderSubsystem {
    let name: String = "Routes"

    /// The unfurl geometry is fully flat by transition 0.9 and the surface mode
    /// flips at 1.0; fade over that tail.
    private static let morphFadeStart: Float = 0.9
    private static let morphFadeEnd: Float = 1.0
    /// 256 bytes of 16-byte points: keeps every per-route buffer offset aligned
    /// for `setVertexBuffer` on every platform.
    private static let pointBufferAlignment = 16
    /// The same 256 bytes, in 4-byte screen lengths.
    private static let screenLengthBufferAlignment = 64

    private let routeSource: RouteRenderSource
    private let pipeline: RoutePipeline
    private let routeDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let presentationStateStore = RoutePresentationStateStore()
    private let pointBufferStore: FrameSlottedDynamicMetalBuffer<RouteWorldGeometryBuilder.Point>
    private let screenLengthBufferStore: FrameSlottedDynamicMetalBuffer<Float>

    private var points: [RouteWorldGeometryBuilder.Point] = []
    private var screenLengthsPx: [Float] = []
    private var drawItems: [RouteDrawItem] = []

    init(routeSource: RouteRenderSource,
         pipeline: RoutePipeline,
         routeDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         metalDevice: MTLDevice) {
        self.routeSource = routeSource
        self.pipeline = pipeline
        self.routeDepthState = routeDepthState
        self.depthDisabledState = depthDisabledState
        self.pointBufferStore = FrameSlottedDynamicMetalBuffer(
            metalDevice: metalDevice,
            slotsCount: InFlightFramePool.inFlightFramesCount,
            options: [.storageModeShared],
            minimumCapacity: 512)
        self.screenLengthBufferStore = FrameSlottedDynamicMetalBuffer(
            metalDevice: metalDevice,
            slotsCount: InFlightFramePool.inFlightFramesCount,
            options: [.storageModeShared],
            minimumCapacity: 512)
    }

    func update(frameContext: FrameContext) {
        if let controller = routeSource.currentRoutesController {
            if let snapshot = controller.consumeSnapshot() {
                presentationStateStore.apply(snapshot: snapshot, time: frameContext.time)
            }
        } else if presentationStateStore.isEmpty == false {
            // A detached controller leaves no snapshot source: clear instead of
            // rendering stale routes forever.
            presentationStateStore.apply(snapshot: RoutesSnapshot(routes: [],
                                                                  progressAnimationsById: [:],
                                                                  removedIds: [],
                                                                  version: 0),
                                         time: frameContext.time)
        }

        let presented = presentationStateStore.presentedEntries(at: frameContext.time)
        frameContext.sharedState.routeState.hasActiveAnimations = presentationStateStore.hasActiveAnimations

        points.removeAll(keepingCapacity: true)
        screenLengthsPx.removeAll(keepingCapacity: true)
        drawItems.removeAll(keepingCapacity: true)

        guard frameContext.renderSurfaceMode == .spherical, presented.isEmpty == false else { return }
        let morphFade = Self.morphFadeAlpha(transition: frameContext.transition)
        guard morphFade > 0 else { return }

        let constants = GeoScreenProjectionMath.FrameConstants(drawSize: frameContext.drawSize,
                                                               cameraUniform: frameContext.cameraUniform,
                                                               resolvedPresentation: frameContext.resolvedPresentation)
        let pixelsPerPoint = Float(max(frameContext.pixelsPerPoint, 1))

        for route in presented {
            let widthPx = Float(route.widthPoints) * pixelsPerPoint
            guard widthPx > 0 else { continue }

            // Sub-pixel lines keep a one-pixel body and pay for the missing
            // width in alpha, so a thin route never flickers in and out.
            var color = route.color
            color.w *= morphFade * min(1, widthPx)
            guard color.w > 0 else { continue }

            let built = RouteWorldGeometryBuilder.build(samples: route.samples,
                                                        progress: route.progress,
                                                        constants: constants)
            guard built.isEmpty == false else { continue }

            let pointOffset = Self.aligned(points.count, to: Self.pointBufferAlignment)
            if pointOffset > points.count {
                points.append(contentsOf: repeatElement(.zero, count: pointOffset - points.count))
            }
            points.append(contentsOf: built.points)

            let screenLengthOffset = Self.aligned(screenLengthsPx.count, to: Self.screenLengthBufferAlignment)
            if screenLengthOffset > screenLengthsPx.count {
                screenLengthsPx.append(contentsOf: repeatElement(0, count: screenLengthOffset - screenLengthsPx.count))
            }
            screenLengthsPx.append(contentsOf: built.screenLengthsPx)

            let dash = route.dash.map { Self.dashPixels($0, pixelsPerPoint: pixelsPerPoint) } ?? SIMD2<Float>(0, 0)
            drawItems.append(RouteDrawItem(
                pointBufferOffsetElements: pointOffset,
                screenLengthBufferOffsetElements: screenLengthOffset,
                pointCount: built.points.count,
                uniform: RouteUniformGPU(viewport: constants.viewport,
                                         halfWidthPx: max(widthPx * 0.5, 0.5),
                                         sampleCount: UInt32(built.points.count),
                                         color: color,
                                         dashPx: dash.x,
                                         gapPx: dash.y)))
        }
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        guard points.isEmpty == false else { return }
        upload(points, into: pointBufferStore, slot: frameContext.frameSlotIndex)
        upload(screenLengthsPx, into: screenLengthBufferStore, slot: frameContext.frameSlotIndex)
    }

    private func upload<Element>(_ values: [Element],
                                 into store: FrameSlottedDynamicMetalBuffer<Element>,
                                 slot: Int) {
        guard values.isEmpty == false else { return }
        let buffer = store.ensureCapacity(slot: slot, count: values.count)
        values.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            buffer.contents().copyMemory(from: baseAddress, byteCount: rawBuffer.count)
        }
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .routes,
              frameContext.renderSurfaceMode == .spherical,
              drawItems.isEmpty == false else {
            return
        }

        // Depth test without depth write: the globe and the scene models in
        // front of the arc already wrote depth, and a translucent ribbon must
        // not occlude itself along the way.
        encoder.setDepthStencilState(routeDepthState)
        RouteDrawer.draw(renderEncoder: encoder,
                         items: drawItems,
                         pointsBuffer: pointBufferStore.buffer(for: frameContext.frameSlotIndex),
                         screenLengthsBuffer: screenLengthBufferStore.buffer(for: frameContext.frameSlotIndex),
                         cameraUniform: frameContext.cameraUniform,
                         pipeline: pipeline)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {
        evict()
    }

    func evict() {
        points = []
        screenLengthsPx = []
        drawItems = []
    }

    /// A dash whose gap would vanish at this scale reads as a solid line, so it
    /// is passed through as one instead of shimmering.
    static func dashPixels(_ dash: ImmersiveMapRouteDash, pixelsPerPoint: Float) -> SIMD2<Float> {
        let dashPx = Float(dash.dashPoints) * pixelsPerPoint
        let gapPx = Float(dash.gapPoints) * pixelsPerPoint
        guard dashPx > 0, gapPx > 0 else { return SIMD2<Float>(0, 0) }
        return SIMD2<Float>(dashPx, gapPx)
    }

    static func morphFadeAlpha(transition: Float) -> Float {
        guard morphFadeEnd > morphFadeStart else {
            return transition >= morphFadeEnd ? 0 : 1
        }
        let normalized = min(max((transition - morphFadeStart) / (morphFadeEnd - morphFadeStart), 0), 1)
        return 1 - normalized * normalized * (3 - 2 * normalized)
    }

    private static func aligned(_ count: Int, to alignment: Int) -> Int {
        let remainder = count % alignment
        return remainder == 0 ? count : count + (alignment - remainder)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import QuartzCore
import simd

enum AvatarDrawPass: Equatable {
    case avatarBody
    case batteryBadge
    case speedBadge
}

private enum AvatarInstanceFlags {
    static let selected: UInt32 = 1 << 0
}

final class AvatarsRenderer {
    private let config: ImmersiveMapSettings.AvatarSettings
    private let avatarPipeline: AvatarPipeline
    private let beamPipeline: AvatarBeamPipeline
    private let batteryBadgePipeline: AvatarBatteryBadgePipeline
    private let speedBadgePipeline: AvatarSpeedBadgePipeline
    private let avatarAtlasResource: LazyAvatarRenderResource<AvatarTextureAtlas>
    private let batteryBadgeAtlasResource: LazyAvatarRenderResource<AvatarBatteryBadgeAtlas>
    private let speedBadgeAtlasResource: LazyAvatarRenderResource<AvatarSpeedBadgeAtlas>
    private let markerSDF: AvatarMarkerSDFResource
    private let markerStyle: AvatarMarkerStyle
    private let batteryBadgeStyle: AvatarBatteryBadgeStyle
    private let speedBadgeStyle: AvatarSpeedBadgeStyle
    private let beamStyle: AvatarBeamStyleGPU
    private let collisionGeometry: AvatarCollisionGeometry
    private let selectionProjector = AvatarSelectionProjector()
    private let collisionLayoutSolver = AvatarCollisionLayoutSolver()
    private let visibilityFadeStateStore = AvatarVisibilityFadeStateStore()

    private let instanceBufferStore: FrameSlottedDynamicMetalBuffer<AvatarInstanceGPU>
    private let screenPointBufferStore: FrameSlottedDynamicMetalBuffer<ScreenPointOutput>
    private let batteryBadgeInstanceBufferStore: FrameSlottedDynamicMetalBuffer<AvatarBatteryBadgeInstanceGPU>
    private let speedBadgeInstanceBufferStore: FrameSlottedDynamicMetalBuffer<AvatarSpeedBadgeInstanceGPU>
    private let beamAnchorBufferStore: FrameSlottedDynamicMetalBuffer<ScreenPointOutput>
    private let beamOffsetBufferStore: FrameSlottedDynamicMetalBuffer<AvatarOffset>
    private let presentationStateStore: AvatarPresentationStateStore
    private var instances: [AvatarInstanceGPU] = []
    private var batteryBadgeInstances: [AvatarBatteryBadgeInstanceGPU] = []
    private var speedBadgeInstances: [AvatarSpeedBadgeInstanceGPU] = []
    private var screenPoints: [ScreenPointOutput] = []
    private var beamAnchors: [ScreenPointOutput] = []
    private var beamOffsets: [AvatarOffset] = []
    private var avatarCount: Int = 0
    private var hasVisibleBatteryBadges: Bool = false
    private var hasVisibleSpeedBadges: Bool = false
    private var hasVisibleBeams: Bool = false
    private var hasAppliedMarkers: Bool = false
    private var frameCounter: UInt64 = 0
    /// Не долитые из-за кадрового бюджета картинки: нужен ещё кадр.
    private var hasPendingAtlasUploads: Bool = false
    /// Лимит растеризаций в атлас на кадр: остальные маркеры появятся в
    /// следующих кадрах, зато кадр не проседает на пачке новых картинок.
    private static let atlasUploadsPerFrameLimit = 24
    private(set) var hasActiveAnimations: Bool = false
    private(set) var selectionSnapshot: AvatarSelectionSnapshot = .empty
    var hasRenderableAvatars: Bool { avatarCount > 0 }
    private var fadeInSeconds: TimeInterval { ImmersiveMapSettings.default.labels.base.fadeInSeconds }
    private var fadeOutSeconds: TimeInterval { ImmersiveMapSettings.default.labels.base.fadeOutSeconds }

    init(metalDevice: MTLDevice,
         layer: CAMetalLayer,
         library: MTLLibrary,
         sampleCount: Int = 1,
         config: ImmersiveMapSettings.AvatarSettings) {
        self.config = config
        self.avatarPipeline = AvatarPipeline(metalDevice: metalDevice,
                                             layer: layer,
                                             library: library,
                                             sampleCount: sampleCount)
        self.beamPipeline = AvatarBeamPipeline(metalDevice: metalDevice,
                                               layer: layer,
                                               library: library,
                                               sampleCount: sampleCount)
        self.batteryBadgePipeline = AvatarBatteryBadgePipeline(metalDevice: metalDevice,
                                                               layer: layer,
                                                               library: library,
                                                               sampleCount: sampleCount)
        self.speedBadgePipeline = AvatarSpeedBadgePipeline(metalDevice: metalDevice,
                                                           layer: layer,
                                                           library: library,
                                                           sampleCount: sampleCount)
        self.instanceBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                  slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                  options: [.storageModeShared])
        self.screenPointBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                     slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                     options: [.storageModeShared])
        self.batteryBadgeInstanceBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                              slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                              options: [.storageModeShared])
        self.speedBadgeInstanceBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                            slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                            options: [.storageModeShared])
        self.beamAnchorBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                    slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                    options: [.storageModeShared])
        self.beamOffsetBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                    slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                    options: [.storageModeShared])
        self.presentationStateStore = AvatarPresentationStateStore()
        self.avatarAtlasResource = LazyAvatarRenderResource {
            AvatarTextureAtlas(device: metalDevice,
                               atlasSize: config.atlasSizePx,
                               cellSize: config.size.rawValue,
                               pagesMax: config.atlasPagesMax)
        }
        let markerSDF = try! AvatarMarkerSDFResource(device: metalDevice)
        self.markerSDF = markerSDF
        let markerSizePx = Float(config.size.rawValue) * config.sizeScale
        let markerStyle = AvatarMarkerStyle(sizePx: markerSizePx,
                                            outlineWidthPx: config.borderWidthPx,
                                            pointerHeightRatio: markerSDF.shapeMetrics.pointerHeightRatio)
        self.markerStyle = markerStyle
        let batteryBadgeStyle = AvatarBatteryBadgeStyle(sizePx: markerSizePx)
        self.batteryBadgeStyle = batteryBadgeStyle
        let speedBadgeStyle = AvatarSpeedBadgeStyle(sizePx: markerSizePx,
                                                    markerStyle: markerStyle)
        self.speedBadgeStyle = speedBadgeStyle
        self.beamStyle = AvatarBeamStyleGPU(markerCenterOffsetPx: markerStyle.pointerHeightPx + markerStyle.bodySizePx.y * 0.5,
                                            markerBodyHalfMinPx: min(markerStyle.bodySizePx.x, markerStyle.bodySizePx.y) * 0.5)
        self.collisionGeometry = AvatarCollisionGeometry(markerSizePx: markerSizePx,
                                                         bodyRadiusPx: max(markerStyle.bodySizePx.x, markerStyle.bodySizePx.y) * 0.5,
                                                         circleBodyRadiusPx: min(markerStyle.bodySizePx.x, markerStyle.bodySizePx.y) * 0.5,
                                                         bodyCenterOffsetPx: markerStyle.pointerHeightPx + markerStyle.bodySizePx.y * 0.5)
        self.batteryBadgeAtlasResource = LazyAvatarRenderResource {
            AvatarBatteryBadgeAtlas(
                device: metalDevice,
                badgePixelSize: SIMD2<Int>(max(1, Int(batteryBadgeStyle.sizePx.x.rounded())),
                                           max(1, Int(batteryBadgeStyle.sizePx.y.rounded())))
            )
        }
        self.speedBadgeAtlasResource = LazyAvatarRenderResource {
            AvatarSpeedBadgeAtlas(
                device: metalDevice,
                badgePixelSize: SIMD2<Int>(max(1, Int(speedBadgeStyle.sizePx.x.rounded())),
                                           max(1, Int(speedBadgeStyle.sizePx.y.rounded()))),
                cornerRadiusPx: speedBadgeStyle.cornerRadiusPx
            )
        }
    }

    func update(controller: ImmersiveMapAvatarsController?, time: TimeInterval) {
        if let snapshot = controller?.consumeSnapshot() {
            apply(snapshot: snapshot, time: time)
        }
        if controller == nil {
            clear(time: time)
        }

        hasActiveAnimations = presentationStateStore.hasActiveAnimations
            || visibilityFadeStateStore.hasActiveAnimations
    }

    private func apply(snapshot: AvatarsSnapshot, time: TimeInterval) {
        // Картинки грузятся в атлас лениво по видимости (rebuildFrameBuffers):
        // атлас ключуется идентичностью картинки и вытесняет LRU-слоты сам.
        presentationStateStore.apply(snapshot: snapshot, time: time)
        hasAppliedMarkers = snapshot.markers.isEmpty == false
    }

    private func clear(time: TimeInterval) {
        guard hasAppliedMarkers else {
            return
        }

        let snapshot = AvatarsSnapshot(markers: [],
                                       removedIds: [],
                                       imageUpdateIds: [],
                                       version: 0)
        apply(snapshot: snapshot, time: time)
    }

    private func makeInstance(marker: AvatarMarker,
                              slot: AvatarAtlasSlot,
                              squashScale: SIMD2<Float>,
                              displayScale: Float,
                              morph: Float) -> AvatarInstanceGPU {
        let border = marker.borderColor ?? config.borderColor
        let flags: UInt32 = marker.isSelected ? AvatarInstanceFlags.selected : 0
        let scaledSquashScale = squashScale * marker.screenSizeScale * displayScale
        return AvatarInstanceGPU(uvRect: slot.uvRect,
                                 borderColor: border,
                                 squashScale: scaledSquashScale,
                                 atlasIndex: UInt32(slot.pageIndex),
                                 flags: flags,
                                 morph: morph)
    }

    static func drawPassSequence(hasVisibleBatteryBadges: Bool,
                                 hasVisibleSpeedBadges: Bool) -> [AvatarDrawPass] {
        var passes: [AvatarDrawPass] = [.avatarBody]
        if hasVisibleBatteryBadges {
            passes.append(.batteryBadge)
        }
        if hasVisibleSpeedBadges {
            passes.append(.speedBadge)
        }
        return passes
    }

    private func makeBatteryBadgeInstance(marker: AvatarMarker,
                                          contentAlpha: Float) -> AvatarBatteryBadgeInstanceGPU {
        guard contentAlpha > 0.0,
              let badge = marker.batteryBadge,
              let slot = batteryBadgeAtlasResource.value.slot(for: badge) else {
            return AvatarBatteryBadgeInstanceGPU(uvRect: .zero,
                                                 flags: 0,
                                                 screenSizeScale: marker.screenSizeScale,
                                                 contentAlpha: 0.0)
        }
        return AvatarBatteryBadgeInstanceGPU(uvRect: slot.uvRect,
                                             flags: 1,
                                             screenSizeScale: marker.screenSizeScale,
                                             contentAlpha: contentAlpha)
    }

    private func makeSpeedBadgeInstance(marker: AvatarMarker,
                                        contentAlpha: Float) -> AvatarSpeedBadgeInstanceGPU {
        guard contentAlpha > 0.0,
              let badge = marker.speedBadge,
              let slot = speedBadgeAtlasResource.value.slot(for: badge) else {
            return AvatarSpeedBadgeInstanceGPU(uvRect: .zero,
                                               flags: 0,
                                               screenSizeScale: marker.screenSizeScale,
                                               contentAlpha: 0.0)
        }
        return AvatarSpeedBadgeInstanceGPU(uvRect: slot.uvRect,
                                           flags: 1,
                                           screenSizeScale: marker.screenSizeScale,
                                           contentAlpha: contentAlpha)
    }

    private func rebuildFrameBuffers(layout: AvatarCollisionLayout,
                                     frameSlotIndex: Int) {
        instances.removeAll(keepingCapacity: true)
        batteryBadgeInstances.removeAll(keepingCapacity: true)
        speedBadgeInstances.removeAll(keepingCapacity: true)
        screenPoints.removeAll(keepingCapacity: true)
        beamAnchors.removeAll(keepingCapacity: true)
        beamOffsets.removeAll(keepingCapacity: true)

        let estimatedCount = layout.markerItems.count
        instances.reserveCapacity(estimatedCount)
        batteryBadgeInstances.reserveCapacity(estimatedCount)
        speedBadgeInstances.reserveCapacity(estimatedCount)
        screenPoints.reserveCapacity(estimatedCount)
        beamAnchors.reserveCapacity(estimatedCount)
        beamOffsets.reserveCapacity(estimatedCount)

        hasVisibleBatteryBadges = false
        hasVisibleSpeedBadges = false
        hasVisibleBeams = false
        hasPendingAtlasUploads = false

        // Пустая сцена не инициализирует ленивые атласы.
        guard layout.markerItems.isEmpty == false else {
            avatarCount = 0
            ensureFrameBufferCapacity(instanceCount: 0, frameSlotIndex: frameSlotIndex)
            return
        }

        frameCounter &+= 1
        let avatarAtlas = avatarAtlasResource.value
        avatarAtlas.beginFrame(frameCounter)
        var uploadBudget = Self.atlasUploadsPerFrameLimit

        for item in layout.markerItems {
            var slot = avatarAtlas.slot(for: item.marker.image)
            if slot == nil {
                if uploadBudget > 0 {
                    // uploadImage возвращает nil, только если атлас целиком
                    // занят картинками текущего кадра - новые кадры не помогут.
                    slot = avatarAtlas.uploadImage(item.marker.image)
                    if slot != nil {
                        uploadBudget -= 1
                    }
                } else {
                    // Кадровый бюджет растеризаций исчерпан: маркер догрузится
                    // в следующих кадрах, нужен ещё один прогон.
                    hasPendingAtlasUploads = true
                }
            }
            guard let slot else {
                continue
            }
            instances.append(makeInstance(marker: item.marker,
                                          slot: slot,
                                          squashScale: item.squashScale,
                                          displayScale: item.displayScale,
                                          morph: item.morph))
            // Бейджи есть только у пина, стоящего на геоточке: у сдвинутого
            // кружка они гаснут вместе с морфом.
            let badgeContentAlpha = AvatarCollisionMath.badgeContentAlpha(displayScale: item.displayScale)
                * (1.0 - item.morph)
            let badgeInstance = makeBatteryBadgeInstance(marker: item.marker,
                                                         contentAlpha: badgeContentAlpha)
            batteryBadgeInstances.append(badgeInstance)
            hasVisibleBatteryBadges = hasVisibleBatteryBadges || (badgeInstance.flags & 1) != 0
            let speedBadgeInstance = makeSpeedBadgeInstance(marker: item.marker,
                                                            contentAlpha: badgeContentAlpha)
            speedBadgeInstances.append(speedBadgeInstance)
            hasVisibleSpeedBadges = hasVisibleSpeedBadges || (speedBadgeInstance.flags & 1) != 0
            screenPoints.append(item.screenPoint)

            // Конус рисуется от истинной геоточки к сдвинутому кружку; альфа
            // якоря берётся с итоговой видимостью маркера, чтобы луч гас
            // вместе с ним.
            var beamAnchor = item.anchorScreenPoint
            beamAnchor.visibilityAlpha = item.screenPoint.visibilityAlpha
            beamAnchors.append(beamAnchor)
            let displacement = item.screenPoint.position - item.anchorScreenPoint.position
            let beamScale = item.displayScale * item.marker.screenSizeScale
            beamOffsets.append(AvatarOffset(value: displacement,
                                            scale: beamScale))
            hasVisibleBeams = hasVisibleBeams
                || simd_length(displacement) > AvatarCollisionMath.displacedMorphStartPx
        }

        avatarCount = instances.count
        ensureFrameBufferCapacity(instanceCount: avatarCount,
                                  frameSlotIndex: frameSlotIndex)
        uploadFrameBuffers(frameSlotIndex: frameSlotIndex)
    }

    private func ensureFrameBufferCapacity(instanceCount: Int,
                                           frameSlotIndex: Int) {
        _ = instanceBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, instanceCount))
        _ = batteryBadgeInstanceBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, instanceCount))
        _ = speedBadgeInstanceBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, instanceCount))
        _ = screenPointBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, instanceCount))
        _ = beamAnchorBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, instanceCount))
        _ = beamOffsetBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, instanceCount))
    }

    private func uploadFrameBuffers(frameSlotIndex: Int) {
        upload(values: instances, to: instanceBufferStore.buffer(for: frameSlotIndex))
        upload(values: batteryBadgeInstances, to: batteryBadgeInstanceBufferStore.buffer(for: frameSlotIndex))
        upload(values: speedBadgeInstances, to: speedBadgeInstanceBufferStore.buffer(for: frameSlotIndex))
        upload(values: screenPoints, to: screenPointBufferStore.buffer(for: frameSlotIndex))
        upload(values: beamAnchors, to: beamAnchorBufferStore.buffer(for: frameSlotIndex))
        upload(values: beamOffsets, to: beamOffsetBufferStore.buffer(for: frameSlotIndex))
    }

    private func upload<T>(values: [T], to buffer: MTLBuffer) {
        guard values.isEmpty == false else { return }
        let bytesCount = values.count * MemoryLayout<T>.stride
        values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: baseAddress, byteCount: bytesCount)
        }
    }

    func compute(drawSize: CGSize,
                 cameraUniform: CameraUniform,
                 resolvedPresentation: ResolvedPresentationState,
                 time: TimeInterval,
                 commandBuffer: MTLCommandBuffer,
                 frameSlotIndex: Int) {
        // Presented-список берётся напрямую из стора и не удерживается между
        // кадрами: стор обновляет кеш на месте, удержание вызвало бы COW-копию
        // всех маркеров каждый анимируемый кадр.
        let presentedMarkers = presentationStateStore.presentedEntries(at: time)
        // Поле отсечения: максимальный вынос коллизиями плюс двойной размер
        // маркера (тело, кольцо цветка, конус к геоточке).
        let cullMarginPx = config.maxOffsetPx + collisionGeometry.markerSizePx * 2.0
        let rawProjectedMarkers = selectionProjector.project(markers: presentedMarkers,
                                                             drawSize: drawSize,
                                                             cameraUniform: cameraUniform,
                                                             resolvedPresentation: resolvedPresentation,
                                                             cullMarginPx: cullMarginPx)
        let fadeResolution = visibilityFadeStateStore.resolve(projectedMarkers: rawProjectedMarkers,
                                                              time: time,
                                                              fadeInSeconds: fadeInSeconds,
                                                              fadeOutSeconds: fadeOutSeconds)
        let layout = collisionLayoutSolver.solve(projectedMarkers: fadeResolution.projectedMarkers,
                                                 geometry: collisionGeometry,
                                                 config: config,
                                                 time: time)
        rebuildFrameBuffers(layout: layout,
                            frameSlotIndex: frameSlotIndex)
        hasActiveAnimations = presentationStateStore.hasActiveAnimations
            || fadeResolution.hasActiveAnimations
            || layout.hasActiveAnimations
            || hasPendingAtlasUploads
        selectionSnapshot = selectionProjector.makeSnapshot(markerItems: layout.markerItems,
                                                            drawSize: drawSize,
                                                            markerStyle: markerStyle,
                                                            badgeStyle: batteryBadgeStyle,
                                                            speedBadgeStyle: speedBadgeStyle)

        guard avatarCount > 0 else {
            return
        }
        _ = commandBuffer
    }

    func drawAvatars(renderEncoder: MTLRenderCommandEncoder,
                     screenMatrix: matrix_float4x4,
                     time: Float,
                     frameSlotIndex: Int) {
        guard avatarCount > 0 else { return }
        var matrix = screenMatrix
        var style = markerStyle.gpu
        var sdfParams = markerSDF.params
        let passes = Self.drawPassSequence(hasVisibleBatteryBadges: hasVisibleBatteryBadges,
                                           hasVisibleSpeedBadges: hasVisibleSpeedBadges)

        if hasVisibleBeams {
            drawBeams(renderEncoder: renderEncoder,
                      matrix: &matrix,
                      frameSlotIndex: frameSlotIndex)
        }

        for pass in passes {
            switch pass {
            case .avatarBody:
                avatarPipeline.selectPipeline(renderEncoder: renderEncoder)
                renderEncoder.setVertexBytes(&matrix, length: MemoryLayout<matrix_float4x4>.stride, index: 0)
                renderEncoder.setVertexBuffer(screenPointBufferStore.buffer(for: frameSlotIndex), offset: 0, index: 1)
                renderEncoder.setVertexBuffer(instanceBufferStore.buffer(for: frameSlotIndex), offset: 0, index: 2)
                renderEncoder.setVertexBytes(&style, length: MemoryLayout<AvatarMarkerStyleGPU>.stride, index: 3)
                renderEncoder.setFragmentBytes(&style, length: MemoryLayout<AvatarMarkerStyleGPU>.stride, index: 0)
                renderEncoder.setFragmentBytes(&sdfParams, length: MemoryLayout<AvatarMarkerSDFParams>.stride, index: 1)
                renderEncoder.setFragmentTexture(avatarAtlasResource.value.textureArray, index: 0)
                renderEncoder.setFragmentTexture(markerSDF.texture, index: 1)
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: avatarCount)
            case .batteryBadge:
                batteryBadgePipeline.selectPipeline(renderEncoder: renderEncoder)
                var badgeStyle = batteryBadgeStyle.gpu
                renderEncoder.setVertexBytes(&matrix, length: MemoryLayout<matrix_float4x4>.stride, index: 0)
                renderEncoder.setVertexBuffer(screenPointBufferStore.buffer(for: frameSlotIndex), offset: 0, index: 1)
                renderEncoder.setVertexBuffer(batteryBadgeInstanceBufferStore.buffer(for: frameSlotIndex), offset: 0, index: 2)
                renderEncoder.setVertexBytes(&badgeStyle, length: MemoryLayout<AvatarBatteryBadgeStyleGPU>.stride, index: 3)
                renderEncoder.setFragmentBytes(&badgeStyle, length: MemoryLayout<AvatarBatteryBadgeStyleGPU>.stride, index: 0)
                renderEncoder.setFragmentTexture(batteryBadgeAtlasResource.value.texture, index: 0)
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: avatarCount)
            case .speedBadge:
                speedBadgePipeline.selectPipeline(renderEncoder: renderEncoder)
                var speedStyle = speedBadgeStyle.gpu
                renderEncoder.setVertexBytes(&matrix, length: MemoryLayout<matrix_float4x4>.stride, index: 0)
                renderEncoder.setVertexBuffer(screenPointBufferStore.buffer(for: frameSlotIndex), offset: 0, index: 1)
                renderEncoder.setVertexBuffer(speedBadgeInstanceBufferStore.buffer(for: frameSlotIndex), offset: 0, index: 2)
                renderEncoder.setVertexBytes(&speedStyle, length: MemoryLayout<AvatarSpeedBadgeStyleGPU>.stride, index: 3)
                renderEncoder.setFragmentTexture(speedBadgeAtlasResource.value.texture, index: 0)
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: avatarCount)
            }
        }
    }

    /// Лучи и точки-якоря рисуются до пузырей: от истинной геоточки к
    /// смещённому маркеру, одним инстансом на маркер.
    private func drawBeams(renderEncoder: MTLRenderCommandEncoder,
                           matrix: inout matrix_float4x4,
                           frameSlotIndex: Int) {
        var beamStyle = beamStyle
        var beamColor = config.beamColor

        beamPipeline.selectBeamPipeline(renderEncoder: renderEncoder)
        renderEncoder.setVertexBytes(&matrix, length: MemoryLayout<matrix_float4x4>.stride, index: 0)
        renderEncoder.setVertexBuffer(beamAnchorBufferStore.buffer(for: frameSlotIndex), offset: 0, index: 1)
        renderEncoder.setVertexBuffer(beamOffsetBufferStore.buffer(for: frameSlotIndex), offset: 0, index: 2)
        renderEncoder.setVertexBytes(&beamStyle, length: MemoryLayout<AvatarBeamStyleGPU>.stride, index: 3)
        renderEncoder.setFragmentBytes(&beamColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: avatarCount)

    }

}

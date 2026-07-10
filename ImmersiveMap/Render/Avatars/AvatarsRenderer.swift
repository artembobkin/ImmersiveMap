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
    private let batteryBadgePipeline: AvatarBatteryBadgePipeline
    private let speedBadgePipeline: AvatarSpeedBadgePipeline
    private let avatarAtlasResource: LazyAvatarRenderResource<AvatarTextureAtlas>
    private let clusterIconAtlasResource: LazyAvatarRenderResource<AvatarClusterIconAtlas>
    private let batteryBadgeAtlasResource: LazyAvatarRenderResource<AvatarBatteryBadgeAtlas>
    private let speedBadgeAtlasResource: LazyAvatarRenderResource<AvatarSpeedBadgeAtlas>
    private let markerSDF: AvatarMarkerSDFResource
    private let markerStyle: AvatarMarkerStyle
    private let batteryBadgeStyle: AvatarBatteryBadgeStyle
    private let speedBadgeStyle: AvatarSpeedBadgeStyle
    private let selectionProjector = AvatarSelectionProjector()
    private let clusterLayoutSolver = AvatarClusterLayoutSolver()
    private let visibilityFadeStateStore = AvatarVisibilityFadeStateStore()

    private let instanceBufferStore: FrameSlottedDynamicMetalBuffer<AvatarInstanceGPU>
    private let screenPointBufferStore: FrameSlottedDynamicMetalBuffer<ScreenPointOutput>
    private let clusterInstanceBufferStore: FrameSlottedDynamicMetalBuffer<AvatarInstanceGPU>
    private let clusterScreenPointBufferStore: FrameSlottedDynamicMetalBuffer<ScreenPointOutput>
    private let batteryBadgeInstanceBufferStore: FrameSlottedDynamicMetalBuffer<AvatarBatteryBadgeInstanceGPU>
    private let speedBadgeInstanceBufferStore: FrameSlottedDynamicMetalBuffer<AvatarSpeedBadgeInstanceGPU>
    private let presentationStateStore: AvatarPresentationStateStore
    private var instances: [AvatarInstanceGPU] = []
    private var batteryBadgeInstances: [AvatarBatteryBadgeInstanceGPU] = []
    private var speedBadgeInstances: [AvatarSpeedBadgeInstanceGPU] = []
    private var screenPoints: [ScreenPointOutput] = []
    private var clusterInstances: [AvatarInstanceGPU] = []
    private var clusterScreenPoints: [ScreenPointOutput] = []
    private var renderableMarkers: [AvatarMarker] = []
    private var presentedEntries: [PresentedAvatarMarker] = []
    private var avatarCount: Int = 0
    private var clusterCount: Int = 0
    private var hasVisibleBatteryBadges: Bool = false
    private var hasVisibleSpeedBadges: Bool = false
    private var markersById: [UInt64: AvatarMarker] = [:]
    private var activeClusterIDs: Set<UInt64> = []
    private(set) var hasActiveAnimations: Bool = false
    private(set) var selectionSnapshot: AvatarSelectionSnapshot = .empty
    var hasRenderableAvatars: Bool { avatarCount > 0 || clusterCount > 0 }
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
        self.clusterInstanceBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                         slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                         options: [.storageModeShared])
        self.clusterScreenPointBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                            slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                            options: [.storageModeShared])
        self.batteryBadgeInstanceBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                              slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                              options: [.storageModeShared])
        self.speedBadgeInstanceBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                            slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                            options: [.storageModeShared])
        self.presentationStateStore = AvatarPresentationStateStore()
        self.avatarAtlasResource = LazyAvatarRenderResource {
            AvatarTextureAtlas(device: metalDevice,
                               atlasSize: config.atlasSizePx,
                               cellSize: config.size.rawValue,
                               pagesMax: config.atlasPagesMax)
        }
        self.clusterIconAtlasResource = LazyAvatarRenderResource {
            AvatarClusterIconAtlas(device: metalDevice,
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
        } else if controller == nil {
            clear(time: time)
        }

        let presentedMarkers = presentationStateStore.presentedEntries(at: time)
        let hasActiveAnimations = presentationStateStore.hasActiveAnimations
        self.presentedEntries = presentedMarkers
        self.hasActiveAnimations = hasActiveAnimations || visibilityFadeStateStore.hasActiveAnimations
    }

    private func apply(snapshot: AvatarsSnapshot, time: TimeInterval) {
        for id in snapshot.removedIds {
            avatarAtlasResource.existingValue?.freeSlot(for: id)
            markersById.removeValue(forKey: id)
        }

        presentationStateStore.apply(snapshot: snapshot, time: time)
        markersById = Dictionary(uniqueKeysWithValues: snapshot.markers.map { ($0.id, $0) })

        if snapshot.imageUpdateIds.isEmpty == false {
            for id in snapshot.imageUpdateIds {
                if let marker = markersById[id] {
                    _ = avatarAtlasResource.value.updateImage(id: id, image: marker.image)
                }
            }
        }

    }

    private func clear(time: TimeInterval) {
        guard markersById.isEmpty == false else {
            return
        }

        let snapshot = AvatarsSnapshot(markers: [],
                                       removedIds: Array(markersById.keys),
                                       imageUpdateIds: [],
                                       version: 0)
        apply(snapshot: snapshot, time: time)
    }

    private func makeInstance(marker: AvatarMarker,
                              slot: AvatarAtlasSlot,
                              squashScale: SIMD2<Float>) -> AvatarInstanceGPU {
        let border = marker.borderColor ?? config.borderColor
        let flags: UInt32 = marker.isSelected ? AvatarInstanceFlags.selected : 0
        let scaledSquashScale = squashScale * marker.screenSizeScale
        return AvatarInstanceGPU(uvRect: slot.uvRect,
                                 borderColor: border,
                                 squashScale: scaledSquashScale,
                                 atlasIndex: UInt32(slot.pageIndex),
                                 flags: flags)
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

    private func makeBatteryBadgeInstance(marker: AvatarMarker) -> AvatarBatteryBadgeInstanceGPU {
        guard let badge = marker.batteryBadge else {
            return AvatarBatteryBadgeInstanceGPU(uvRect: .zero,
                                                 flags: 0,
                                                 screenSizeScale: marker.screenSizeScale,
                                                 _padding: .zero)
        }
        guard let slot = batteryBadgeAtlasResource.value.slot(for: badge) else {
            return AvatarBatteryBadgeInstanceGPU(uvRect: .zero,
                                                 flags: 0,
                                                 screenSizeScale: marker.screenSizeScale,
                                                 _padding: .zero)
        }
        return AvatarBatteryBadgeInstanceGPU(uvRect: slot.uvRect,
                                             flags: 1,
                                             screenSizeScale: marker.screenSizeScale,
                                             _padding: .zero)
    }

    private func makeSpeedBadgeInstance(marker: AvatarMarker) -> AvatarSpeedBadgeInstanceGPU {
        guard let badge = marker.speedBadge else {
            return AvatarSpeedBadgeInstanceGPU(uvRect: .zero,
                                               flags: 0,
                                               screenSizeScale: marker.screenSizeScale,
                                               _padding: .zero)
        }
        guard let slot = speedBadgeAtlasResource.value.slot(for: badge) else {
            return AvatarSpeedBadgeInstanceGPU(uvRect: .zero,
                                               flags: 0,
                                               screenSizeScale: marker.screenSizeScale,
                                               _padding: .zero)
        }
        return AvatarSpeedBadgeInstanceGPU(uvRect: slot.uvRect,
                                           flags: 1,
                                           screenSizeScale: marker.screenSizeScale,
                                           _padding: .zero)
    }

    private func rebuildFrameBuffers(layout: AvatarClusterLayout,
                                     frameSlotIndex: Int) {
        instances.removeAll(keepingCapacity: true)
        batteryBadgeInstances.removeAll(keepingCapacity: true)
        speedBadgeInstances.removeAll(keepingCapacity: true)
        screenPoints.removeAll(keepingCapacity: true)
        clusterInstances.removeAll(keepingCapacity: true)
        clusterScreenPoints.removeAll(keepingCapacity: true)
        renderableMarkers.removeAll(keepingCapacity: true)

        instances.reserveCapacity(layout.markerItems.count)
        batteryBadgeInstances.reserveCapacity(layout.markerItems.count)
        speedBadgeInstances.reserveCapacity(layout.markerItems.count)
        screenPoints.reserveCapacity(layout.markerItems.count)
        clusterInstances.reserveCapacity(layout.clusterItems.count)
        clusterScreenPoints.reserveCapacity(layout.clusterItems.count)

        hasVisibleBatteryBadges = false
        hasVisibleSpeedBadges = false

        for item in layout.markerItems {
            let avatarAtlas = avatarAtlasResource.value
            guard let slot = avatarAtlas.slot(for: item.marker.id)
                    ?? avatarAtlas.updateImage(id: item.marker.id, image: item.marker.image) else {
                continue
            }
            instances.append(makeInstance(marker: item.marker,
                                          slot: slot,
                                          squashScale: item.squashScale))
            let badgeInstance = makeBatteryBadgeInstance(marker: item.marker)
            batteryBadgeInstances.append(badgeInstance)
            hasVisibleBatteryBadges = hasVisibleBatteryBadges || (badgeInstance.flags & 1) != 0
            let speedBadgeInstance = makeSpeedBadgeInstance(marker: item.marker)
            speedBadgeInstances.append(speedBadgeInstance)
            hasVisibleSpeedBadges = hasVisibleSpeedBadges || (speedBadgeInstance.flags & 1) != 0
            screenPoints.append(item.screenPoint)
            renderableMarkers.append(item.marker)
        }

        for cluster in layout.clusterItems {
            guard let slot = clusterIconAtlasResource.value.update(cluster: cluster) else {
                continue
            }
            clusterInstances.append(makeClusterInstance(slot: slot))
            clusterScreenPoints.append(cluster.screenPoint)
        }

        avatarCount = instances.count
        clusterCount = clusterInstances.count
        ensureFrameBufferCapacity(markerCount: avatarCount,
                                  clusterCount: clusterCount,
                                  frameSlotIndex: frameSlotIndex)
        uploadFrameBuffers(frameSlotIndex: frameSlotIndex)
    }

    private func ensureFrameBufferCapacity(markerCount: Int,
                                           clusterCount: Int,
                                           frameSlotIndex: Int) {
        _ = instanceBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, markerCount))
        _ = batteryBadgeInstanceBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, markerCount))
        _ = speedBadgeInstanceBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, markerCount))
        _ = screenPointBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, markerCount))
        _ = clusterInstanceBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, clusterCount))
        _ = clusterScreenPointBufferStore.ensureCapacity(slot: frameSlotIndex, count: max(1, clusterCount))
    }

    private func uploadFrameBuffers(frameSlotIndex: Int) {
        upload(values: instances, to: instanceBufferStore.buffer(for: frameSlotIndex))
        upload(values: batteryBadgeInstances, to: batteryBadgeInstanceBufferStore.buffer(for: frameSlotIndex))
        upload(values: speedBadgeInstances, to: speedBadgeInstanceBufferStore.buffer(for: frameSlotIndex))
        upload(values: screenPoints, to: screenPointBufferStore.buffer(for: frameSlotIndex))
        upload(values: clusterInstances, to: clusterInstanceBufferStore.buffer(for: frameSlotIndex))
        upload(values: clusterScreenPoints, to: clusterScreenPointBufferStore.buffer(for: frameSlotIndex))
    }

    private func upload<T>(values: [T], to buffer: MTLBuffer) {
        guard values.isEmpty == false else { return }
        let bytesCount = values.count * MemoryLayout<T>.stride
        values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: baseAddress, byteCount: bytesCount)
        }
    }

    private func makeClusterInstance(slot: AvatarAtlasSlot) -> AvatarInstanceGPU {
        AvatarInstanceGPU(uvRect: slot.uvRect,
                          borderColor: config.borderColor,
                          squashScale: SIMD2<Float>(repeating: 1.0),
                          atlasIndex: UInt32(slot.pageIndex),
                          flags: 0)
    }

    func compute(drawSize: CGSize,
                 cameraUniform: CameraUniform,
                 resolvedPresentation: ResolvedPresentationState,
                 time: TimeInterval,
                 commandBuffer: MTLCommandBuffer,
                 frameSlotIndex: Int) {
        let rawProjectedMarkers = selectionProjector.project(markers: presentedEntries,
                                                             drawSize: drawSize,
                                                             cameraUniform: cameraUniform,
                                                             resolvedPresentation: resolvedPresentation)
        let fadeResolution = visibilityFadeStateStore.resolve(projectedMarkers: rawProjectedMarkers,
                                                              time: time,
                                                              fadeInSeconds: fadeInSeconds,
                                                              fadeOutSeconds: fadeOutSeconds)
        hasActiveAnimations = presentationStateStore.hasActiveAnimations || fadeResolution.hasActiveAnimations
        let markerSizePx = Float(config.size.rawValue) * config.sizeScale
        let layout = clusterLayoutSolver.solve(projectedMarkers: fadeResolution.projectedMarkers,
                                               markerSizePx: markerSizePx,
                                               collisionPaddingPx: config.collisionPaddingPx)

        if let clusterIconAtlas = clusterIconAtlasResource.existingValue {
            for staleClusterID in activeClusterIDs.subtracting(layout.activeClusterIDs) {
                clusterIconAtlas.freeSlot(for: staleClusterID)
            }
        }
        rebuildFrameBuffers(layout: layout,
                            frameSlotIndex: frameSlotIndex)
        selectionSnapshot = selectionProjector.makeSnapshot(markerItems: layout.markerItems,
                                                            clusterItems: layout.clusterItems,
                                                            drawSize: drawSize,
                                                            markerStyle: markerStyle,
                                                            badgeStyle: batteryBadgeStyle,
                                                            speedBadgeStyle: speedBadgeStyle)
        activeClusterIDs = layout.activeClusterIDs

        guard avatarCount > 0 || clusterCount > 0 else {
            return
        }
        _ = commandBuffer
    }

    func drawAvatars(renderEncoder: MTLRenderCommandEncoder,
                     screenMatrix: matrix_float4x4,
                     time: Float,
                     frameSlotIndex: Int) {
        guard avatarCount > 0 || clusterCount > 0 else { return }
        var matrix = screenMatrix
        var style = markerStyle.gpu
        var sdfParams = markerSDF.params
        let passes = Self.drawPassSequence(hasVisibleBatteryBadges: hasVisibleBatteryBadges,
                                           hasVisibleSpeedBadges: hasVisibleSpeedBadges)

        if clusterCount > 0 {
            avatarPipeline.selectPipeline(renderEncoder: renderEncoder)
            renderEncoder.setVertexBytes(&matrix, length: MemoryLayout<matrix_float4x4>.stride, index: 0)
            renderEncoder.setVertexBuffer(clusterScreenPointBufferStore.buffer(for: frameSlotIndex), offset: 0, index: 1)
            renderEncoder.setVertexBuffer(clusterInstanceBufferStore.buffer(for: frameSlotIndex), offset: 0, index: 2)
            renderEncoder.setVertexBytes(&style, length: MemoryLayout<AvatarMarkerStyleGPU>.stride, index: 3)
            renderEncoder.setFragmentBytes(&style, length: MemoryLayout<AvatarMarkerStyleGPU>.stride, index: 0)
            renderEncoder.setFragmentBytes(&sdfParams, length: MemoryLayout<AvatarMarkerSDFParams>.stride, index: 1)
            renderEncoder.setFragmentTexture(clusterIconAtlasResource.value.textureArray, index: 0)
            renderEncoder.setFragmentTexture(markerSDF.texture, index: 1)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: clusterCount)
        }

        guard avatarCount > 0 else { return }

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

}

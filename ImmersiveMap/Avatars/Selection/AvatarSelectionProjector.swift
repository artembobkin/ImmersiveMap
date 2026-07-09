// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  AvatarSelectionProjector.swift
//  ImmersiveMap
//

import CoreGraphics
import simd

enum AvatarSelectionTarget: Equatable {
    case marker(UInt64)
    case cluster(UInt64)
}

struct AvatarSelectionEntry {
    let target: AvatarSelectionTarget
    let bounds: CGRect
    let anchorPoint: CGPoint
    let drawOrder: Int

    init(markerID: UInt64,
         bounds: CGRect,
         anchorPoint: CGPoint,
         drawOrder: Int) {
        self.target = .marker(markerID)
        self.bounds = bounds
        self.anchorPoint = anchorPoint
        self.drawOrder = drawOrder
    }

    init(target: AvatarSelectionTarget,
         bounds: CGRect,
         anchorPoint: CGPoint,
         drawOrder: Int) {
        self.target = target
        self.bounds = bounds
        self.anchorPoint = anchorPoint
        self.drawOrder = drawOrder
    }

    var markerID: UInt64? {
        if case .marker(let id) = target {
            return id
        }
        return nil
    }
}

struct AvatarSelectionSnapshot {
    static let empty = AvatarSelectionSnapshot(frameIndex: 0,
                                               drawSize: .zero,
                                               entries: [])

    let frameIndex: UInt64
    let drawSize: CGSize
    let entries: [AvatarSelectionEntry]

    func withFrameIndex(_ frameIndex: UInt64) -> AvatarSelectionSnapshot {
        AvatarSelectionSnapshot(frameIndex: frameIndex,
                                drawSize: drawSize,
                                entries: entries)
    }

    func hitTest(point: CGPoint) -> AvatarSelectionTarget? {
        for entry in entries.reversed() where entry.bounds.contains(point) {
            return entry.target
        }
        return nil
    }
}

struct AvatarSelectionProjector {
    private let globeHorizonFadeBandWidth: Float = 0.03

    func makeSnapshot(markers: [AvatarMarker],
                      drawSize: CGSize,
                      cameraUniform: CameraUniform,
                      resolvedPresentation: ResolvedPresentationState,
                      markerStyle: AvatarMarkerStyle,
                      badgeStyle: AvatarBatteryBadgeStyle,
                      speedBadgeStyle: AvatarSpeedBadgeStyle) -> AvatarSelectionSnapshot {
        let projected = project(markers: markers.map { PresentedAvatarMarker(marker: $0,
                                                                              squashScale: SIMD2<Float>(repeating: 1)) },
                                drawSize: drawSize,
                                cameraUniform: cameraUniform,
                                resolvedPresentation: resolvedPresentation)
        return makeSnapshot(markerItems: projected.map {
            AvatarClusterMarkerItem(marker: $0.marker,
                                    squashScale: $0.squashScale,
                                    screenPoint: $0.screenPoint,
                                    drawOrder: $0.drawOrder)
        },
        clusterItems: [],
        drawSize: drawSize,
        markerStyle: markerStyle,
        badgeStyle: badgeStyle,
        speedBadgeStyle: speedBadgeStyle)
    }

    func project(markers: [PresentedAvatarMarker],
                 drawSize: CGSize,
                 cameraUniform: CameraUniform,
                 resolvedPresentation: ResolvedPresentationState) -> [AvatarProjectedMarker] {
        guard markers.isEmpty == false,
              drawSize.width > 0,
              drawSize.height > 0 else {
            return []
        }

        let viewport = SIMD2<Float>(Float(drawSize.width), Float(drawSize.height))
        var projectedMarkers: [AvatarProjectedMarker] = []
        projectedMarkers.reserveCapacity(markers.count)

        switch resolvedPresentation.screenSpaceProjectionMode {
        case .flat:
            for (drawOrder, presentedMarker) in markers.enumerated() {
                let marker = presentedMarker.marker
                let latitude = marker.coordinate.latitude * .pi / 180.0
                let longitude = marker.coordinate.longitude * .pi / 180.0
                let worldPosition = ImmersiveMapProjection.flatWorldPosition(latitude: latitude,
                                                                    longitude: longitude,
                                                                    flatRenderPan: resolvedPresentation.flatRenderState.pan,
                                                                    renderMapSize: resolvedPresentation.flatRenderState.renderMapSize)
                let clip = cameraUniform.matrix * SIMD4<Float>(worldPosition.x, worldPosition.y, 0.0, 1.0)
                let point = screenPointFromClip(clip: clip, viewportSize: viewport)
                appendProjectedIfVisible(presentedMarker: presentedMarker,
                                         screenPoint: point,
                                         drawOrder: drawOrder,
                                         projectedMarkers: &projectedMarkers)
            }
        case .globe:
            let constants = GlobeProjectionConstants(globe: resolvedPresentation.globeRenderUniform)
            for (drawOrder, presentedMarker) in markers.enumerated() {
                let marker = presentedMarker.marker
                let latitude = Float(marker.coordinate.latitude * .pi / 180.0)
                let longitude = Float(marker.coordinate.longitude * .pi / 180.0)
                let projection = globeProjectLatLon(latitude: latitude,
                                                    longitude: longitude,
                                                    cameraUniform: cameraUniform,
                                                    constants: constants)
                var point = screenPointFromClip(clip: projection.clip, viewportSize: viewport)
                if point.visible != 0 {
                    let visibility = globeProjectionVisibility(worldPosition: projection.worldPosition,
                                                               cameraUniform: cameraUniform,
                                                               constants: constants)
                    point.visibilityAlpha = visibility.alpha
                }
                appendProjectedIfVisible(presentedMarker: presentedMarker,
                                         screenPoint: point,
                                         drawOrder: drawOrder,
                                         projectedMarkers: &projectedMarkers)
            }
        }

        return projectedMarkers
    }

    func makeSnapshot(markerItems: [AvatarClusterMarkerItem],
                      clusterItems: [AvatarClusterRenderable],
                      drawSize: CGSize,
                      markerStyle: AvatarMarkerStyle,
                      badgeStyle: AvatarBatteryBadgeStyle,
                      speedBadgeStyle: AvatarSpeedBadgeStyle) -> AvatarSelectionSnapshot {
        guard drawSize.width > 0,
              drawSize.height > 0 else {
            return .empty
        }

        let width = CGFloat(markerStyle.totalSizePx.x)
        let height = CGFloat(markerStyle.totalSizePx.y)
        var entries: [AvatarSelectionEntry] = []
        entries.reserveCapacity(markerItems.count + clusterItems.count)

        for cluster in clusterItems {
            appendEntryIfVisible(target: .cluster(cluster.id),
                                 hasBatteryBadge: false,
                                 hasSpeedBadge: false,
                                 screenPoint: cluster.screenPoint,
                                 drawOrder: cluster.drawOrder,
                                 markerWidth: width,
                                 markerHeight: height,
                                 badgeStyle: badgeStyle,
                                 speedBadgeStyle: speedBadgeStyle,
                                 entries: &entries)
        }

        for markerItem in markerItems {
            appendEntryIfVisible(target: .marker(markerItem.marker.id),
                                 hasBatteryBadge: markerItem.marker.batteryBadge != nil,
                                 hasSpeedBadge: markerItem.marker.speedBadge != nil,
                                 screenPoint: markerItem.screenPoint,
                                 drawOrder: markerItem.drawOrder,
                                 markerWidth: width,
                                 markerHeight: height,
                                 badgeStyle: badgeStyle,
                                 speedBadgeStyle: speedBadgeStyle,
                                 entries: &entries)
        }

        return AvatarSelectionSnapshot(frameIndex: 0,
                                       drawSize: drawSize,
                                       entries: entries)
    }

    private func appendProjectedIfVisible(presentedMarker: PresentedAvatarMarker,
                                          screenPoint: ScreenPointOutput,
                                          drawOrder: Int,
                                          projectedMarkers: inout [AvatarProjectedMarker]) {
        guard screenPoint.visible != 0 else {
            return
        }

        projectedMarkers.append(AvatarProjectedMarker(marker: presentedMarker.marker,
                                                      squashScale: presentedMarker.squashScale,
                                                      screenPoint: screenPoint,
                                                      drawOrder: drawOrder))
    }

    private func appendEntryIfVisible(target: AvatarSelectionTarget,
                                      hasBatteryBadge: Bool,
                                      hasSpeedBadge: Bool,
                                      screenPoint: ScreenPointOutput,
                                      drawOrder: Int,
                                      markerWidth: CGFloat,
                                      markerHeight: CGFloat,
                                      badgeStyle: AvatarBatteryBadgeStyle,
                                     speedBadgeStyle: AvatarSpeedBadgeStyle,
                                     entries: inout [AvatarSelectionEntry]) {
        guard screenPoint.visible != 0 else {
            return
        }
        guard screenPoint.visibilityAlpha > AvatarVisibilityFadeStateStore.activeAlphaThreshold else {
            return
        }

        let anchorPoint = CGPoint(x: CGFloat(screenPoint.position.x),
                                  y: CGFloat(screenPoint.position.y))
        let bounds = selectionBounds(anchorPoint: anchorPoint,
                                     hasBatteryBadge: hasBatteryBadge,
                                     hasSpeedBadge: hasSpeedBadge,
                                     markerWidth: markerWidth,
                                     markerHeight: markerHeight,
                                     badgeStyle: badgeStyle,
                                     speedBadgeStyle: speedBadgeStyle)
        entries.append(AvatarSelectionEntry(target: target,
                                            bounds: bounds,
                                            anchorPoint: anchorPoint,
                                            drawOrder: drawOrder))
    }

    func selectionBounds(anchorPoint: CGPoint,
                         hasBatteryBadge: Bool,
                         hasSpeedBadge: Bool,
                         markerWidth: CGFloat,
                         markerHeight: CGFloat,
                         badgeStyle: AvatarBatteryBadgeStyle,
                         speedBadgeStyle: AvatarSpeedBadgeStyle) -> CGRect {
        var bounds = CGRect(x: anchorPoint.x - markerWidth * 0.5,
                            y: anchorPoint.y,
                            width: markerWidth,
                            height: markerHeight)
        if hasBatteryBadge {
            let batteryRect = CGRect(x: anchorPoint.x - CGFloat(badgeStyle.sizePx.x) * 0.5,
                                     y: anchorPoint.y - CGFloat(badgeStyle.bottomExtensionPx),
                                     width: CGFloat(badgeStyle.sizePx.x),
                                     height: CGFloat(badgeStyle.sizePx.y))
            bounds = bounds.union(batteryRect)
        }
        if hasSpeedBadge {
            let speedRect = CGRect(x: anchorPoint.x + CGFloat(speedBadgeStyle.gpu.originXPx),
                                   y: anchorPoint.y + CGFloat(speedBadgeStyle.gpu.originYPx),
                                   width: CGFloat(speedBadgeStyle.sizePx.x),
                                   height: CGFloat(speedBadgeStyle.sizePx.y))
            bounds = bounds.union(speedRect)
        }
        return bounds
    }

    private func screenPointFromClip(clip: SIMD4<Float>,
                                     viewportSize: SIMD2<Float>) -> ScreenPointOutput {
        guard clip.w > 0.0 else {
            return ScreenPointOutput(position: .zero,
                                     depth: 0.0,
                                     visible: 0,
                                     visibilityAlpha: 0.0)
        }

        let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
        let depth = clip.z / clip.w
        let position = (ndc * 0.5 + 0.5) * viewportSize
        return ScreenPointOutput(position: position,
                                 depth: depth,
                                 visible: 1,
                                 visibilityAlpha: 1.0)
    }

    private func globeProjectLatLon(latitude: Float,
                                    longitude: Float,
                                    cameraUniform: CameraUniform,
                                    constants: GlobeProjectionConstants) -> GlobeProjectionResult {
        let sphereWorldPosition = constants.rotatedSphereWorldPosition(latitude: latitude,
                                                                       longitude: longitude)
        let flatWorldPosition = constants.flatWorldPosition(latitude: latitude,
                                                            longitude: longitude)
        let transition = constants.globe.transition
        let worldPosition = sphereWorldPosition + (flatWorldPosition - sphereWorldPosition) * transition
        let clip = cameraUniform.matrix * SIMD4<Float>(worldPosition, 1.0)
        return GlobeProjectionResult(clip: clip, worldPosition: worldPosition)
    }

    private func globeProjectionVisibility(worldPosition: SIMD3<Float>,
                                           cameraUniform: CameraUniform,
                                           constants: GlobeProjectionConstants) -> (visible: Bool, alpha: Float) {
        let globeCenter = SIMD3<Float>(0.0, 0.0, -constants.globe.radius)
        let toCamera = cameraUniform.eye - globeCenter
        if simd_length(toCamera) <= 0.0 || constants.globe.transition >= 0.95 {
            return (true, 1.0)
        }

        let toCameraLength = simd_length(toCamera)
        let radius = max(constants.globe.radius, 1e-6)
        let dotToCamera = simd_dot(worldPosition - globeCenter, toCamera)
        let normalization = max(toCameraLength * radius, 1e-6)
        let normalizedDot = dotToCamera / normalization
        let normalizedThreshold = constants.horizonThreshold / normalization
        let visibilityDelta = normalizedDot - normalizedThreshold

        if visibilityDelta <= -globeHorizonFadeBandWidth {
            return (false, 0.0)
        }

        let alpha = smoothstep(edge0: -globeHorizonFadeBandWidth,
                               edge1: globeHorizonFadeBandWidth,
                               x: visibilityDelta)
        return (true, alpha)
    }

    private func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = simd_clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)
    }
}

private struct GlobeProjectionResult {
    let clip: SIMD4<Float>
    let worldPosition: SIMD3<Float>
}

private struct GlobeProjectionConstants {
    let globe: GlobeUniform
    let panLatitude: Float
    let panLongitude: Float
    let mapSize: Float
    let panMercatorY: Float
    let rotationMatrix: matrix_float4x4
    let horizonThreshold: Float

    init(globe: GlobeUniform) {
        self.globe = globe
        let maxLatitude = Float(ImmersiveMapProjection.maxMercatorLatitude)
        self.panLatitude = globe.panY * maxLatitude
        self.panLongitude = globe.panX * .pi
        let distortion = cos(panLatitude)
        let mapSizeScale = (1.0 - globe.transition) * distortion + globe.transition
        self.mapSize = 2.0 * .pi * globe.radius * mapSizeScale
        self.panMercatorY = Float(ImmersiveMapProjection.yMercatorNormalized(latitude: Double(panLatitude)))
        self.rotationMatrix = GlobeProjectionConstants.makeRotationMatrix(panLatitude: panLatitude,
                                                                          panLongitude: panLongitude)
        let horizonFade = GlobeProjectionConstants.smoothstep(edge0: 0.8,
                                                              edge1: 0.95,
                                                              x: globe.transition)
        self.horizonThreshold = (1.0 - horizonFade) * (globe.radius * globe.radius) + horizonFade * -1e6
    }

    func rotatedSphereWorldPosition(latitude: Float,
                                    longitude: Float) -> SIMD3<Float> {
        let phi = latitude - (.pi * 0.5)
        let theta = longitude + .pi

        let x = globe.radius * sin(phi) * sin(theta)
        let y = globe.radius * cos(phi)
        let z = globe.radius * sin(phi) * cos(theta)
        let rotatedPosition = simd_transpose(rotationMatrix) * SIMD4<Float>(x, y, z, 1.0)
        return SIMD3<Float>(rotatedPosition.x,
                            rotatedPosition.y,
                            rotatedPosition.z - globe.radius)
    }

    func flatWorldPosition(latitude: Float,
                           longitude: Float) -> SIMD3<Float> {
        let normalizedWorldX = (longitude + .pi) / (2.0 * .pi)
        let mercatorY = Float(ImmersiveMapProjection.yMercatorNormalized(latitude: Double(latitude)))
        let halfMapSize = mapSize * 0.5
        let worldX = normalizedWorldX * mapSize
        let panOffsetX = globe.panX * halfMapSize
        let wrappedXInput = worldX - halfMapSize + panOffsetX
        let x = ImmersiveMapProjection.wrap(value: Double(wrappedXInput),
                                   size: Double(mapSize))
        let y = Double((mercatorY - panMercatorY) * halfMapSize)
        return SIMD3<Float>(Float(x), Float(y), 0.0)
    }

    private static func makeRotationMatrix(panLatitude: Float,
                                           panLongitude: Float) -> matrix_float4x4 {
        let xRotation = matrix_float4x4(SIMD4<Float>(1, 0, 0, 0),
                                        SIMD4<Float>(0, cos(panLatitude), -sin(panLatitude), 0),
                                        SIMD4<Float>(0, sin(panLatitude), cos(panLatitude), 0),
                                        SIMD4<Float>(0, 0, 0, 1))
        let yRotation = matrix_float4x4(SIMD4<Float>(cos(panLongitude), 0, sin(panLongitude), 0),
                                        SIMD4<Float>(0, 1, 0, 0),
                                        SIMD4<Float>(-sin(panLongitude), 0, cos(panLongitude), 0),
                                        SIMD4<Float>(0, 0, 0, 1))
        return matrix_multiply(yRotation, xRotation)
    }

    private static func smoothstep(edge0: Float,
                                   edge1: Float,
                                   x: Float) -> Float {
        let t = simd_clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)
    }
}

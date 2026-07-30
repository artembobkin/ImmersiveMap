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
    /// Проецирует маркеры на экран общим проектором GeoScreenProjectionMath:
    /// та же математика, что у тайлов и SwiftUI-маркеров (волна морфа и
    /// мягкий горизонт), иначе аватары «плывут» относительно поверхности в
    /// середине перехода. Отбрасывает всё за пределами вьюпорта с полем
    /// `cullMarginPx` (запас на вынос коллизиями и размер маркера) и
    /// невидимую сторону глобуса. Тригонометрии на маркер нет - только
    /// линейная математика от кешированного базиса координаты.
    func project(markers: [PresentedAvatarMarker],
                 drawSize: CGSize,
                 cameraUniform: CameraUniform,
                 resolvedPresentation: ResolvedPresentationState,
                 cullMarginPx: Float) -> [AvatarProjectedMarker] {
        guard markers.isEmpty == false,
              drawSize.width > 0,
              drawSize.height > 0 else {
            return []
        }

        let constants = GeoScreenProjectionMath.FrameConstants(drawSize: drawSize,
                                                               cameraUniform: cameraUniform,
                                                               resolvedPresentation: resolvedPresentation)
        let viewport = constants.viewport
        var projectedMarkers: [AvatarProjectedMarker] = []
        projectedMarkers.reserveCapacity(min(markers.count, 4096))

        func isInsideViewport(_ point: ScreenPointOutput, screenSizeScale: Float) -> Bool {
            let margin = cullMarginPx * max(1.0, screenSizeScale)
            return point.position.x >= -margin
                && point.position.x <= viewport.x + margin
                && point.position.y >= -margin
                && point.position.y <= viewport.y + margin
        }

        for presentedMarker in markers {
            let point = GeoScreenProjectionMath.project(basis: presentedMarker.projectionBasis,
                                                        constants: constants)
            // Обратная сторона шара и точки за камерой не доходят до солвера.
            guard point.visible != 0,
                  point.visibilityAlpha > 0.0,
                  isInsideViewport(point, screenSizeScale: presentedMarker.marker.screenSizeScale) else {
                continue
            }
            appendProjectedIfVisible(presentedMarker: presentedMarker,
                                     screenPoint: point,
                                     drawOrder: presentedMarker.drawOrder,
                                     projectedMarkers: &projectedMarkers)
        }

        return projectedMarkers
    }

    func makeSnapshot(markerItems: [AvatarCollisionMarkerItem],
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
        entries.reserveCapacity(markerItems.count)

        for markerItem in markerItems {
            // Сжатый маркер занимает меньше места и прячет бейджи: хит-зона
            // масштабируется тем же displayScale, что и отрисовка.
            let displayScale = CGFloat(max(markerItem.displayScale, 0.0))
            let badgesVisible = AvatarCollisionMath.badgeContentAlpha(displayScale: markerItem.displayScale) > 0.0
            appendEntryIfVisible(target: .marker(markerItem.marker.id),
                                 hasBatteryBadge: badgesVisible && markerItem.marker.batteryBadge != nil,
                                 hasSpeedBadge: badgesVisible && markerItem.marker.speedBadge != nil,
                                 screenPoint: markerItem.screenPoint,
                                 drawOrder: markerItem.drawOrder,
                                 markerWidth: width * displayScale,
                                 markerHeight: height * displayScale,
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

        let basis = presentedMarker.projectionBasis
        projectedMarkers.append(AvatarProjectedMarker(marker: presentedMarker.marker,
                                                      squashScale: presentedMarker.squashScale,
                                                      screenPoint: screenPoint,
                                                      worldPosition: SIMD2<Double>(basis.normalizedWorldX,
                                                                                   basis.mercatorYNormalized),
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

}

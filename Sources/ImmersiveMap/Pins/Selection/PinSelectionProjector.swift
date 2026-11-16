// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  PinSelectionProjector.swift
//  ImmersiveMap
//

import CoreGraphics
import simd

enum PinSelectionTarget: Equatable {
    case pin(UInt64)
}

struct PinSelectionEntry {
    let target: PinSelectionTarget
    let bounds: CGRect
    let anchorPoint: CGPoint
    let drawOrder: Int

    init(pinID: UInt64,
         bounds: CGRect,
         anchorPoint: CGPoint,
         drawOrder: Int) {
        self.target = .pin(pinID)
        self.bounds = bounds
        self.anchorPoint = anchorPoint
        self.drawOrder = drawOrder
    }

    init(target: PinSelectionTarget,
         bounds: CGRect,
         anchorPoint: CGPoint,
         drawOrder: Int) {
        self.target = target
        self.bounds = bounds
        self.anchorPoint = anchorPoint
        self.drawOrder = drawOrder
    }

    var pinID: UInt64? {
        if case .pin(let id) = target {
            return id
        }
        return nil
    }
}

struct PinSelectionSnapshot: SelectionPickData {
    var kind: ImmersiveMapSelection.Kind { .pin }

    static let empty = PinSelectionSnapshot(frameIndex: 0,
                                               drawSize: .zero,
                                               entries: [])

    let frameIndex: UInt64
    let drawSize: CGSize
    let entries: [PinSelectionEntry]

    func withFrameIndex(_ frameIndex: UInt64) -> PinSelectionSnapshot {
        PinSelectionSnapshot(frameIndex: frameIndex,
                                drawSize: drawSize,
                                entries: entries)
    }

    func hitTest(point: CGPoint) -> PinSelectionTarget? {
        for entry in entries.reversed() where entry.bounds.contains(point) {
            return entry.target
        }
        return nil
    }
}

struct PinSelectionProjector {
    /// Projects pins onto the screen via the shared GeoScreenProjectionMath
    /// projector: the same math as tiles and SwiftUI pins (morph wave and
    /// soft horizon), otherwise pins "swim" relative to the surface in the
    /// middle of the transition. Discards everything outside the viewport with
    /// a `cullMarginPx` margin (headroom for collision displacement and pin
    /// size) and the invisible side of the globe. No per-pin trigonometry -
    /// only linear math from the coordinate's cached basis.
    func project(pins: [PresentedPin],
                 drawSize: CGSize,
                 cameraUniform: CameraUniform,
                 resolvedPresentation: ResolvedPresentationState,
                 cullMarginPx: Float) -> [ProjectedPin] {
        guard pins.isEmpty == false,
              drawSize.width > 0,
              drawSize.height > 0 else {
            return []
        }

        let constants = GeoScreenProjectionMath.FrameConstants(drawSize: drawSize,
                                                               cameraUniform: cameraUniform,
                                                               resolvedPresentation: resolvedPresentation)
        let viewport = constants.viewport
        var projectedPins: [ProjectedPin] = []
        projectedPins.reserveCapacity(min(pins.count, 4096))

        func isInsideViewport(_ point: ScreenPointOutput, screenSizeScale: Float) -> Bool {
            let margin = cullMarginPx * max(1.0, screenSizeScale)
            return point.position.x >= -margin
                && point.position.x <= viewport.x + margin
                && point.position.y >= -margin
                && point.position.y <= viewport.y + margin
        }

        for presentedPin in pins {
            let point = GeoScreenProjectionMath.project(basis: presentedPin.projectionBasis,
                                                        constants: constants)
            // The far side of the globe and points behind the camera never reach the solver.
            guard point.visible != 0,
                  point.visibilityAlpha > 0.0,
                  isInsideViewport(point, screenSizeScale: presentedPin.pin.screenSizeScale) else {
                continue
            }
            appendProjectedIfVisible(presentedPin: presentedPin,
                                     screenPoint: point,
                                     drawOrder: presentedPin.drawOrder,
                                     projectedPins: &projectedPins)
        }

        return projectedPins
    }

    func makeSnapshot(pinItems: [PinCollisionItem],
                      drawSize: CGSize,
                      pinStyle: PinStyle) -> PinSelectionSnapshot {
        guard drawSize.width > 0,
              drawSize.height > 0 else {
            return .empty
        }

        let width = CGFloat(pinStyle.totalSizePx.x)
        let height = CGFloat(pinStyle.totalSizePx.y)
        let origin = pinStyle.quadOriginPx
        var entries: [PinSelectionEntry] = []
        entries.reserveCapacity(pinItems.count)

        for pinItem in pinItems {
            // A shrunken pin takes less space: the hit zone scales with the
            // same displayScale as the rendering.
            let displayScale = CGFloat(max(pinItem.displayScale, 0.0))
            appendEntryIfVisible(target: .pin(pinItem.pin.id),
                                 screenPoint: pinItem.screenPoint,
                                 drawOrder: pinItem.drawOrder,
                                 pinOrigin: CGPoint(x: CGFloat(origin.x) * displayScale,
                                                    y: CGFloat(origin.y) * displayScale),
                                 pinWidth: width * displayScale,
                                 pinHeight: height * displayScale,
                                 entries: &entries)
        }

        return PinSelectionSnapshot(frameIndex: 0,
                                       drawSize: drawSize,
                                       entries: entries)
    }

    private func appendProjectedIfVisible(presentedPin: PresentedPin,
                                          screenPoint: ScreenPointOutput,
                                          drawOrder: Int,
                                          projectedPins: inout [ProjectedPin]) {
        guard screenPoint.visible != 0 else {
            return
        }

        let basis = presentedPin.projectionBasis
        projectedPins.append(ProjectedPin(pin: presentedPin.pin,
                                                      squashScale: presentedPin.squashScale,
                                                      screenPoint: screenPoint,
                                                      worldPosition: SIMD2<Double>(basis.normalizedWorldX,
                                                                                   basis.mercatorYNormalized),
                                                      drawOrder: drawOrder))
    }

    private func appendEntryIfVisible(target: PinSelectionTarget,
                                      screenPoint: ScreenPointOutput,
                                      drawOrder: Int,
                                      pinOrigin: CGPoint,
                                      pinWidth: CGFloat,
                                      pinHeight: CGFloat,
                                      entries: inout [PinSelectionEntry]) {
        guard screenPoint.visible != 0 else {
            return
        }
        guard screenPoint.visibilityAlpha > PinVisibilityFadeStateStore.activeAlphaThreshold else {
            return
        }

        let anchorPoint = CGPoint(x: CGFloat(screenPoint.position.x),
                                  y: CGFloat(screenPoint.position.y))
        let bounds = selectionBounds(anchorPoint: anchorPoint,
                                     pinOrigin: pinOrigin,
                                     pinWidth: pinWidth,
                                     pinHeight: pinHeight)
        entries.append(PinSelectionEntry(target: target,
                                            bounds: bounds,
                                            anchorPoint: anchorPoint,
                                            drawOrder: drawOrder))
    }

    /// The pin's quad on the screen: `pinOrigin` is its lower left corner
    /// from the anchor, which depends on where the shape's anchor is.
    func selectionBounds(anchorPoint: CGPoint,
                         pinOrigin: CGPoint,
                         pinWidth: CGFloat,
                         pinHeight: CGFloat) -> CGRect {
        CGRect(x: anchorPoint.x + pinOrigin.x,
               y: anchorPoint.y + pinOrigin.y,
               width: pinWidth,
               height: pinHeight)
    }

}

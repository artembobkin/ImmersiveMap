// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit
import SwiftUI

/// Прозрачный контейнер SwiftUI-маркеров поверх Metal-слоя. Занимает весь
/// host view, но клики получает только контент маркеров: «пустые» точки
/// проваливаются в карту, и `MapGestureControllerMac` через `hitTest`
/// автоматически подавляет жесты карты над интерактивным маркером
/// (прецеденты: AttributionBadgeView, DebugOverlayHUDView).
final class MarkerOverlayContainerView: NSView {
    /// Top-left origin, как у flipped `ImmersiveMapNSView`: математика
    /// раскладки маркеров едина с UIKit.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
}

/// Обёртка одного маркера: владеет `NSHostingView` контента и переключает
/// интерактивность через hitTest (у NSView нет isUserInteractionEnabled).
@MainActor
final class MarkerOverlayItemHost {
    private final class ItemView: NSView {
        override var isFlipped: Bool { true }
        var isInteractionEnabled = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard isInteractionEnabled else {
                return nil
            }
            return super.hitTest(point)
        }
    }

    private let itemView: ItemView
    private let hostingView: NSHostingView<AnyView>

    var view: NSView {
        itemView
    }

    init(content: AnyView) {
        hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = [.intrinsicContentSize]
        itemView = ItemView(frame: .zero)
        // alphaValue требует слоя, host view и так layer-backed.
        itemView.wantsLayer = true
        itemView.isHidden = true
        hostingView.autoresizingMask = [.width, .height]
        itemView.addSubview(hostingView)
    }

    func update(content: AnyView) {
        hostingView.rootView = content
    }

    func idealSize() -> CGSize {
        hostingView.fittingSize
    }

    func apply(frame: CGRect, alpha: CGFloat) {
        itemView.frame = frame
        hostingView.frame = itemView.bounds
        itemView.alphaValue = alpha
        itemView.isHidden = false
        itemView.isInteractionEnabled = alpha > MarkerOverlayLayoutMath.interactionAlphaThreshold
    }

    func hide() {
        itemView.isHidden = true
        itemView.isInteractionEnabled = false
    }

    func removeFromContainer() {
        itemView.removeFromSuperview()
    }
}

#endif

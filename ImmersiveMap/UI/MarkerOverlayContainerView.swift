// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import SwiftUI
import UIKit

/// Прозрачный контейнер SwiftUI-маркеров поверх Metal-слоя. Занимает весь
/// host view, но касания получает только контент маркеров: «пустые» точки
/// проваливаются в карту (прецеденты: AttributionBadgeView,
/// DebugOverlayHUDView).
final class MarkerOverlayContainerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        return result === self ? nil : result
    }
}

/// Обёртка одного маркера: владеет `UIHostingController` контента и
/// переключает интерактивность (маркер у горизонта с почти нулевой alpha
/// не должен ловить касания).
@MainActor
final class MarkerOverlayItemHost {
    /// Без parent view controller: контент маркера замкнутый лист
    /// (navigation/presentation изнутри не поддержаны, см. docs/markers.md),
    /// traits приходят через окно.
    private let hostingController: UIHostingController<AnyView>

    var view: UIView {
        hostingController.view
    }

    init(content: AnyView) {
        hostingController = UIHostingController(rootView: content)
        hostingController.view.backgroundColor = .clear
        hostingController.view.isHidden = true
        hostingController.sizingOptions = [.intrinsicContentSize]
        // Клавиатура и safe area не должны двигать контент маркера.
        hostingController.safeAreaRegions = []
    }

    func update(content: AnyView) {
        hostingController.rootView = content
    }

    func idealSize() -> CGSize {
        hostingController.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude))
    }

    func apply(frame: CGRect, alpha: CGFloat) {
        view.frame = frame
        view.alpha = alpha
        view.isHidden = false
        view.isUserInteractionEnabled = alpha > MarkerOverlayLayoutMath.interactionAlphaThreshold
    }

    func hide() {
        view.isHidden = true
        view.isUserInteractionEnabled = false
    }

    func removeFromContainer() {
        view.removeFromSuperview()
    }
}

#endif

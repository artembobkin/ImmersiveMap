// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import UIKit

/// Прозрачная UIKit hit-test surface для map control zones.
/// Не владеет состоянием карты; конкретные control-zone классы цепляют gestures и управляют layout.
final class ControlZoneView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

#endif

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI

/// Один SwiftUI-маркер после eager-вычисления ViewBuilder в body:
/// публичный Identifiable-id, координата и стёртый контент.
/// Не Sendable (AnyView): живёт только на MainActor и ходит по цепочке
/// representable -> host view -> host runtime -> marker runtime.
struct MarkerViewItem {
    let id: AnyHashable
    let coordinate: GeoCoordinate
    let content: AnyView
}

/// Полный набор маркеров одного вызова `.markers(...)`: повторный вызов
/// заменяет предыдущий набор целиком.
struct MarkerViewContent {
    let anchor: UnitPoint
    let items: [MarkerViewItem]
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI

/// One SwiftUI marker after eager ViewBuilder evaluation in body:
/// the public Identifiable id, the coordinate, and the type-erased content.
/// Not Sendable (AnyView): lives only on the MainActor and travels along the chain
/// representable -> host view -> host runtime -> marker runtime.
struct MarkerViewItem {
    let id: AnyHashable
    let coordinate: GeoCoordinate
    let content: AnyView
}

/// The full marker set of one `.markers(...)` call: a repeated call
/// replaces the previous set entirely.
struct MarkerViewContent {
    let anchor: UnitPoint
    let items: [MarkerViewItem]
}

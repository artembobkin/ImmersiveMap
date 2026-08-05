// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Snapshot of route mutations collected by the public controller and consumed
/// destructively by the render subsystem.
struct RoutesSnapshot {
    let routes: [ImmersiveMapRoute]
    /// Duration of the progress animation requested for a route in this
    /// snapshot; absent means snap.
    let progressAnimationDurationsById: [UInt64: TimeInterval]
    let removedIds: [UInt64]
    let version: UInt64
}

/// The single seam between the renderer and UI-side route ownership.
protocol RouteRenderSource: AnyObject {
    var currentRoutesController: ImmersiveMapRoutesController? { get }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A progress animation requested for a route. `startProgress` is what the
/// route showed when the app asked, which is the only way a route that is added
/// and animated before its first frame can animate at all: the descriptor by
/// then already carries the target.
struct RouteProgressAnimationRequest {
    let startProgress: Double
    let duration: TimeInterval
}

/// Snapshot of route mutations collected by the public controller and consumed
/// destructively by the render subsystem.
struct RoutesSnapshot {
    let routes: [ImmersiveMapRoute]
    /// Progress animations requested for routes in this snapshot; absent means
    /// snap.
    let progressAnimationsById: [UInt64: RouteProgressAnimationRequest]
    let removedIds: [UInt64]
    let version: UInt64
}

/// The single seam between the renderer and UI-side route ownership.
protocol RouteRenderSource: AnyObject {
    var currentRoutesController: ImmersiveMapRoutesController? { get }
}

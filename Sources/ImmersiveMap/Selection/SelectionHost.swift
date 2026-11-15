// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics

/// What the selection needs of the map view it serves: the view's scale,
/// and a frame when the selection changed what the map shows. The view's
/// runtimes stand behind it (`ImmersiveMapSelectionHost` in `UI/Runtime`),
/// so nothing of the selection depends on `UI`.
@MainActor
protocol SelectionHost: AnyObject {
    /// The drawable's pixels to a point of the view.
    var contentsScale: CGFloat { get }
    func requestFrame()
}

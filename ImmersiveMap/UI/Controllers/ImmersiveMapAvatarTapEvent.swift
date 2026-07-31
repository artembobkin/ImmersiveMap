// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics

/// Tap event on a map avatar marker.
/// Delivered on every tap on a marker regardless of selection state,
/// including a repeated tap on an already selected marker.
public struct ImmersiveMapAvatarTapEvent {
    /// Snapshot of the marker at the moment of the tap.
    public let marker: AvatarMarker
    /// Tap point in map view coordinates.
    public let screenPoint: CGPoint

    public init(marker: AvatarMarker,
                screenPoint: CGPoint) {
        self.marker = marker
        self.screenPoint = screenPoint
    }
}

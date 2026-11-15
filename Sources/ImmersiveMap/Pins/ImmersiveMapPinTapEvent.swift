// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics

/// Tap event on a map pin pin.
/// Delivered on every tap on a pin regardless of selection state,
/// including a repeated tap on an already selected pin.
public struct ImmersiveMapPinTapEvent {
    /// Snapshot of the pin at the moment of the tap.
    public let pin: ImmersiveMapPin
    /// Tap point in map view coordinates.
    public let screenPoint: CGPoint

    public init(pin: ImmersiveMapPin,
                screenPoint: CGPoint) {
        self.pin = pin
        self.screenPoint = screenPoint
    }
}

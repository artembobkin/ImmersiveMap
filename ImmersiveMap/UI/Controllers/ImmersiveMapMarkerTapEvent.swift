// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics

/// Событие нажатия на avatar marker карты.
/// Доставляется на каждый tap по маркеру независимо от selection state,
/// в том числе повторный tap по уже выбранному маркеру.
public struct ImmersiveMapMarkerTapEvent {
    /// Снапшот маркера на момент нажатия.
    public let marker: AvatarMarker
    /// Точка нажатия в координатах map view.
    public let screenPoint: CGPoint

    public init(marker: AvatarMarker,
                screenPoint: CGPoint) {
        self.marker = marker
        self.screenPoint = screenPoint
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// Владеет состоянием SwiftUI-маркеров на стороне UI: отдаёт движку кадра
/// текущий набор координат (`MarkerRenderSource`) и принимает пер-кадровые
/// снапшоты проекции. Движок читает источник и публикует снапшот синхронно
/// на main thread внутри кадра, поэтому оба конца остаются на MainActor.
@MainActor
final class ImmersiveMapMarkerRuntime: @preconcurrency MarkerRenderSource {
    private let viewportRuntime: ImmersiveMapViewportRuntime
    private let renderRuntime: ImmersiveMapRenderRuntime

    private var projectionInput: MarkerProjectionInput = .empty
    private(set) var lastAppliedSnapshot: MarkerProjectionSnapshot?

    init(viewportRuntime: ImmersiveMapViewportRuntime,
         renderRuntime: ImmersiveMapRenderRuntime) {
        self.viewportRuntime = viewportRuntime
        self.renderRuntime = renderRuntime
    }

    var currentMarkerProjectionInput: MarkerProjectionInput {
        projectionInput
    }

    func apply(_ snapshot: MarkerProjectionSnapshot) {
        lastAppliedSnapshot = snapshot
    }
}

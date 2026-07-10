// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Отслеживает active user-interaction sources одного map view.
/// Обновляет render-loop interaction activity и отправляет camera interaction notifications.
final class ImmersiveMapInteractionRuntime {
    enum Source: Hashable {
        case mapPan
        case mapPinch
        case mapRotation
        case pitchControl
        case zoomControl
        case scrollZoom
    }

    private let cameraRuntime: ImmersiveMapCameraRuntime
    private let renderRuntime: ImmersiveMapRenderRuntime
    private var activeSources: Set<Source> = []

    init(cameraRuntime: ImmersiveMapCameraRuntime,
         renderRuntime: ImmersiveMapRenderRuntime) {
        self.cameraRuntime = cameraRuntime
        self.renderRuntime = renderRuntime
    }

    var hasActiveUserInteraction: Bool {
        activeSources.isEmpty == false
    }

    func setActive(_ isActive: Bool,
                   source: Source,
                   notifiesUserInteractionBegan: Bool,
                   requestsFrameOnStart: Bool = false) {
        let wasInteracting = hasActiveUserInteraction

        if isActive {
            activeSources.insert(source)
        } else {
            activeSources.remove(source)
        }

        if isActive && wasInteracting == false && notifiesUserInteractionBegan {
            cameraRuntime.notifyUserInteractionBegan()
        }

        renderRuntime.setInteractionRenderingActive(hasActiveUserInteraction)

        if isActive && requestsFrameOnStart {
            renderRuntime.requestFrame()
        }
    }
}

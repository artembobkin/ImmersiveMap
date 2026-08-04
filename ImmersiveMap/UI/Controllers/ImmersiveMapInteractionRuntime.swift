// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Tracks active user-interaction sources of a single map view.
/// Updates render-loop interaction activity and sends camera interaction notifications.
@MainActor
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

    /// Clears every active source when the view parks in the reuse pool.
    /// A gesture interrupted by the view leaving the window never delivers its
    /// end event (raw macOS scroll phases especially), and a source stuck
    /// active would keep the render loop hot and cancel the adopting screen's
    /// first camera flight.
    func resetForParking() {
        guard activeSources.isEmpty == false else {
            return
        }
        activeSources.removeAll()
        renderRuntime.setInteractionRenderingActive(false)
    }
}

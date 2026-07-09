// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import QuartzCore
import UIKit

#if DEBUG
extension ImmersiveMapUIView {
    func flyForTesting(to cameraPosition: ImmersiveMapCameraPosition,
                       options: CameraFlightOptions = .default,
                       completion: ((Bool) -> Void)? = nil,
                       currentTime: CFTimeInterval) {
        cameraAnimationRuntime.startCameraFlight(to: cameraPosition,
                                                 options: options,
                                                 completion: completion,
                                                 currentTime: currentTime)
    }

    func advanceCameraFlightForTesting(currentTime: CFTimeInterval) {
        cameraAnimationRuntime.advanceCameraFlightIfNeeded(currentTime: currentTime)
    }

    func setPanInteractionActiveForTesting(_ isActive: Bool) {
        gestureController.setPanInteractionActiveForTesting(isActive)
    }

    var hasActiveCameraFlightForTesting: Bool {
        cameraAnimationRuntime.isCameraFlightActive
    }

    var isCameraAnimationRenderingActiveForTesting: Bool {
        renderRuntime.cameraAnimationRenderingActive
    }

    func simulateBackgroundTapForTesting(at point: CGPoint) {
        tapHandler.handleBackgroundTap(at: point)
    }

    func simulateMapTapForTesting(at point: CGPoint) {
        tapHandler.handleMapTap(at: point)
    }

    func setAvatarSelectionSnapshotForTesting(_ snapshot: AvatarSelectionSnapshot) {
        selectionHandler.updateAvatarSelectionSnapshot(snapshot)
    }
}
#endif

#endif

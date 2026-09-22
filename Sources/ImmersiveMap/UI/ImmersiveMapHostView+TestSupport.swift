// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import QuartzCore

#if DEBUG
extension ImmersiveMapHostView {
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

    func followForTesting(path: ImmersiveMapGeoPath,
                          duration: TimeInterval,
                          curve: ImmersiveMapPathAnimationCurve = .linear,
                          options: ImmersiveMapCameraFollowOptions = .default,
                          completion: ((Bool) -> Void)? = nil,
                          currentTime: CFTimeInterval) {
        cameraAnimationRuntime.startCameraPathFollow(path: path,
                                                     duration: duration,
                                                     curve: curve,
                                                     options: options,
                                                     completion: completion,
                                                     currentTime: currentTime)
    }

    func advanceCameraPathFollowForTesting(currentTime: CFTimeInterval) {
        cameraAnimationRuntime.advanceCameraPathFollowIfNeeded(currentTime: currentTime)
    }

    var hasActiveCameraPathFollowForTesting: Bool {
        cameraAnimationRuntime.isCameraPathFollowActive
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

    func setSceneModelSelectionSnapshotForTesting(_ snapshot: SceneModelSelectionSnapshot) {
        selectionHandler.updateSceneModelSelectionSnapshot(snapshot)
    }

    var rendererForTesting: RenderFrameEngine? {
        hostRuntimeForTesting.renderer
    }
}
#endif

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import QuartzCore

/// Applies `ImmersiveMapCameraController` commands to the camera runtime.
/// Uses only narrow dependencies for applying the camera position and starting camera animations.
@MainActor
final class ImmersiveMapCameraCommandHandler {
    private let cameraRuntime: ImmersiveMapCameraRuntime
    private let cameraAnimationRuntime: ImmersiveMapCameraAnimationRuntime

    init(cameraRuntime: ImmersiveMapCameraRuntime,
         cameraAnimationRuntime: ImmersiveMapCameraAnimationRuntime) {
        self.cameraRuntime = cameraRuntime
        self.cameraAnimationRuntime = cameraAnimationRuntime
    }

    func handle(_ command: ImmersiveMapCameraCommand) {
        switch command {
        case .jump(let position):
            // A jump is a camera set from outside. Applied once, it is a
            // one-shot frame; applied once per frame by an app driving the
            // camera itself, it must keep the display link running the way a
            // gesture does, or every frame pauses and resumes the link.
            if applyCameraPosition(position) {
                cameraRuntime.noteExternalCameraDrive()
            }
        case .fly(let position, let options, let completion):
            cameraAnimationRuntime.startCameraFlight(to: position,
                                                     options: options,
                                                     completion: completion,
                                                     currentTime: CACurrentMediaTime())
        case .follow(let path, let duration, let curve, let options, let completion):
            cameraAnimationRuntime.startCameraPathFollow(path: path,
                                                         duration: duration,
                                                         curve: curve,
                                                         options: options,
                                                         completion: completion,
                                                         currentTime: CACurrentMediaTime())
        case .cancelFollow:
            cameraAnimationRuntime.cancelCameraPathFollow()
        case .cancelFlight:
            cameraAnimationRuntime.cancelCameraFlight()
        case .setAngleTarget(let bearing, let pitch):
            cameraAnimationRuntime.setCameraAngleTarget(bearing: bearing, pitch: pitch)
        }
    }

    /// Returns whether the position differed from the applied one and was
    /// applied.
    @discardableResult
    func applyCameraPosition(_ cameraPosition: ImmersiveMapCameraPosition?) -> Bool {
        guard cameraRuntime.needsCameraPositionUpdate(cameraPosition) else {
            return false
        }

        cameraAnimationRuntime.cancelAnimations()
        cameraRuntime.applyCameraPosition(cameraPosition)
        return true
    }
}

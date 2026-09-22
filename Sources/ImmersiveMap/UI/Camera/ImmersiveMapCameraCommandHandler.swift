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
            // The controller's jump goes where it says, every time: also
            // back to the position of the previous jump after a gesture
            // moved the camera away. The dedup against the last declared
            // position (`applyCameraPosition`) belongs to the SwiftUI
            // modifier path alone, which re-declares the same position on
            // every update and must not snap the camera back after a
            // gesture. Applied once per frame by an app driving the camera
            // itself, the jump keeps the display link running the way a
            // gesture does, or every frame would pause and resume the link.
            cameraAnimationRuntime.cancelAnimations()
            cameraRuntime.setCameraPosition(position)
            cameraRuntime.noteExternalCameraDrive()
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

    /// The SwiftUI-declared position: applied only when it differs from the
    /// last declared one, since SwiftUI re-declares it on every update and a
    /// repeat must not move a camera the user has since dragged elsewhere.
    func applyCameraPosition(_ cameraPosition: ImmersiveMapCameraPosition?) {
        guard cameraRuntime.needsCameraPositionUpdate(cameraPosition) else {
            return
        }

        cameraAnimationRuntime.cancelAnimations()
        cameraRuntime.applyCameraPosition(cameraPosition)
    }
}

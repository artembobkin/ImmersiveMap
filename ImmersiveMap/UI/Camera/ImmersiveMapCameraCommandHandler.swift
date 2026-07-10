// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import QuartzCore

/// Применяет команды `ImmersiveMapCameraController` к camera runtime.
/// Использует только узкие зависимости для применения позиции камеры и запуска camera animations.
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
            applyCameraPosition(position)
        case .fly(let position, let options, let completion):
            cameraAnimationRuntime.startCameraFlight(to: position,
                                                     options: options,
                                                     completion: completion,
                                                     currentTime: CACurrentMediaTime())
        case .cancelFlight:
            cameraAnimationRuntime.cancelCameraFlight()
        case .setAngleTarget(let bearing, let pitch):
            cameraAnimationRuntime.setCameraAngleTarget(bearing: bearing, pitch: pitch)
        }
    }

    func applyCameraPosition(_ cameraPosition: ImmersiveMapCameraPosition?) {
        guard cameraRuntime.needsCameraPositionUpdate(cameraPosition) else {
            return
        }

        cameraAnimationRuntime.cancelAnimations()
        cameraRuntime.applyCameraPosition(cameraPosition)
    }
}

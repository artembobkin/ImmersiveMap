// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct CameraConstraints {
    let bearing: CameraBearingConstraint
    let pitch: CameraPitchConstraint
}

struct CameraBearingConstraint {
    let maximumAbsoluteBearing: Float?

    func apply(to bearing: Float) -> Float {
        let normalizedBearing = CameraBearingConstraintResolver.normalized(bearing)
        guard let maximumAbsoluteBearing else {
            return normalizedBearing
        }

        let clampedLimit = min(max(maximumAbsoluteBearing, 0), .pi)
        return min(max(normalizedBearing, -clampedLimit), clampedLimit)
    }
}

struct CameraPitchConstraint {
    let minimumPitch: Float
    let maximumPitch: Float

    var clampedMaximumPitch: Float {
        max(maximumPitch, 0)
    }

    /// The floor never rises above the ceiling, so an inverted range collapses
    /// to the ceiling instead of deadlocking the camera.
    var clampedMinimumPitch: Float {
        min(max(minimumPitch, 0), clampedMaximumPitch)
    }

    func apply(to pitch: Float) -> Float {
        min(max(pitch, clampedMinimumPitch), clampedMaximumPitch)
    }
}

enum CameraConstraintResolver {
    static func resolve(cameraState: ImmersiveMapCameraState,
                        cameraSettings: ImmersiveMapSettings.CameraSettings,
                        renderSurfaceMode: ViewMode) -> CameraConstraints {
        CameraConstraints(
            bearing: CameraBearingConstraintResolver.resolve(cameraState: cameraState,
                                                             cameraSettings: cameraSettings,
                                                             renderSurfaceMode: renderSurfaceMode),
            pitch: CameraPitchConstraintResolver.resolve(cameraState: cameraState,
                                                         cameraSettings: cameraSettings,
                                                         renderSurfaceMode: renderSurfaceMode)
        )
    }
}

enum CameraBearingConstraintResolver {
    static func resolve(cameraState: ImmersiveMapCameraState,
                        cameraSettings: ImmersiveMapSettings.CameraSettings,
                        renderSurfaceMode: ViewMode) -> CameraBearingConstraint {
        guard renderSurfaceMode == .spherical else {
            return CameraBearingConstraint(maximumAbsoluteBearing: cameraSettings.maximumAbsoluteBearing)
        }

        return CameraBearingConstraint(
            maximumAbsoluteBearing: globeMaximumAbsoluteBearing(zoom: cameraState.zoom,
                                                                cameraSettings: cameraSettings)
        )
    }

    static func globeMaximumAbsoluteBearing(zoom: Double,
                                            cameraSettings: ImmersiveMapSettings.CameraSettings) -> Float {
        // The configured cap is the widest the globe's bearing window opens; a
        // cap below the window's floor collapses the window to the cap.
        let ceiling = min(max(cameraSettings.maximumAbsoluteBearing ?? .pi, 0), .pi)
        let minimumBearing = min(max(cameraSettings.globeMinimumAbsoluteBearing, 0), ceiling)
        let unlockZoom = max(cameraSettings.globeBearingUnlockZoom, 0)
        guard unlockZoom > Double.leastNonzeroMagnitude else {
            return ceiling
        }

        let progress = min(max(zoom / unlockZoom, 0), 1)
        return minimumBearing + (ceiling - minimumBearing) * Float(progress)
    }

    static func normalized(_ bearing: Float) -> Float {
        let twoPi = Float.pi * 2
        var normalized = (bearing + .pi).truncatingRemainder(dividingBy: twoPi)
        if normalized < 0 {
            normalized += twoPi
        }
        return normalized - .pi
    }
}

enum CameraPitchConstraintResolver {
    static func resolve(cameraState: ImmersiveMapCameraState,
                        cameraSettings: ImmersiveMapSettings.CameraSettings,
                        renderSurfaceMode: ViewMode) -> CameraPitchConstraint {
        guard renderSurfaceMode == .spherical else {
            return CameraPitchConstraint(minimumPitch: cameraSettings.minimumPitch,
                                         maximumPitch: cameraSettings.maximumReachablePitch(at: cameraState.zoom))
        }

        return CameraPitchConstraint(
            minimumPitch: cameraSettings.minimumPitch,
            maximumPitch: globeMaximumPitch(zoom: cameraState.zoom,
                                            cameraSettings: cameraSettings)
        )
    }

    static func globeMaximumPitch(zoom: Double,
                                  cameraSettings: ImmersiveMapSettings.CameraSettings) -> Float {
        let maximumPitch = cameraSettings.maximumReachablePitch(at: zoom)
        let unlockZoom = max(cameraSettings.globePitchUnlockZoom, 0)
        guard unlockZoom > Double.leastNonzeroMagnitude else {
            return maximumPitch
        }

        let progress = min(max(zoom / unlockZoom, 0), 1)
        return maximumPitch * Float(progress)
    }
}

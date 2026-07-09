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
    let maximumPitch: Float

    func apply(to pitch: Float) -> Float {
        let clampedMaximumPitch = max(maximumPitch, 0)
        return min(max(pitch, 0), clampedMaximumPitch)
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
            return CameraBearingConstraint(maximumAbsoluteBearing: nil)
        }

        return CameraBearingConstraint(
            maximumAbsoluteBearing: globeMaximumAbsoluteBearing(zoom: cameraState.zoom,
                                                                cameraSettings: cameraSettings)
        )
    }

    static func globeMaximumAbsoluteBearing(zoom: Double,
                                            cameraSettings: ImmersiveMapSettings.CameraSettings) -> Float {
        let minimumBearing = min(max(cameraSettings.globeMinimumAbsoluteBearing, 0), .pi)
        let unlockZoom = max(cameraSettings.globeBearingUnlockZoom, 0)
        guard unlockZoom > Double.leastNonzeroMagnitude else {
            return .pi
        }

        let progress = min(max(zoom / unlockZoom, 0), 1)
        return minimumBearing + (Float.pi - minimumBearing) * Float(progress)
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
            return CameraPitchConstraint(maximumPitch: cameraSettings.maximumReachablePitch(at: cameraState.zoom))
        }

        return CameraPitchConstraint(
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

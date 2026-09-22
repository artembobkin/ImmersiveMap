// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

enum ImmersiveMapCameraSnapshotResolver {
    static func resolve(position: ImmersiveMapCameraPosition,
                        constraints: CameraConstraints,
                        isSphericalSurfaceActive: Bool) -> ImmersiveMapCameraSnapshot {
        let bearingLimits = ImmersiveMapCameraBearingLimits(maximumAbsoluteBearing: constraints.bearing.maximumAbsoluteBearing ?? .pi)
        let pitchLimits = ImmersiveMapCameraAngleLimits(minimum: constraints.pitch.clampedMinimumPitch,
                                                        maximum: constraints.pitch.clampedMaximumPitch)
        let snapshot = ImmersiveMapCameraSnapshot(position: position,
                                                  bearingLimits: bearingLimits,
                                                  pitchLimits: pitchLimits,
                                                  isSphericalSurfaceActive: isSphericalSurfaceActive)
        return ImmersiveMapCameraSnapshot(position: snapshot.clampedPosition(position),
                                          bearingLimits: bearingLimits,
                                          pitchLimits: pitchLimits,
                                          isSphericalSurfaceActive: isSphericalSurfaceActive)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

public struct ImmersiveMapCameraAngleLimits: Equatable, Sendable {
    public let minimum: Float
    public let maximum: Float

    public init(minimum: Float, maximum: Float) {
        self.minimum = min(minimum, maximum)
        self.maximum = max(minimum, maximum)
    }

    public func clamped(_ value: Float) -> Float {
        min(max(value, minimum), maximum)
    }
}

public struct ImmersiveMapCameraBearingLimits: Equatable, Sendable {
    public let maximumAbsoluteBearing: Float

    public var minimum: Float {
        -maximumAbsoluteBearing
    }

    public var maximum: Float {
        maximumAbsoluteBearing
    }

    public init(maximumAbsoluteBearing: Float) {
        self.maximumAbsoluteBearing = min(max(maximumAbsoluteBearing, 0), Float.pi)
    }

    public func clamped(_ bearing: Float) -> Float {
        min(max(ImmersiveMapCameraSnapshot.normalizedBearing(bearing), minimum), maximum)
    }
}

public struct ImmersiveMapCameraSnapshot: Equatable, Sendable {
    public let position: ImmersiveMapCameraPosition
    public let bearingLimits: ImmersiveMapCameraBearingLimits
    public let pitchLimits: ImmersiveMapCameraAngleLimits
    public let isSphericalSurfaceActive: Bool

    public init(position: ImmersiveMapCameraPosition,
                bearingLimits: ImmersiveMapCameraBearingLimits,
                pitchLimits: ImmersiveMapCameraAngleLimits,
                isSphericalSurfaceActive: Bool) {
        self.position = position
        self.bearingLimits = bearingLimits
        self.pitchLimits = pitchLimits
        self.isSphericalSurfaceActive = isSphericalSurfaceActive
    }

    public func clampedPosition(_ position: ImmersiveMapCameraPosition) -> ImmersiveMapCameraPosition {
        ImmersiveMapCameraPosition(latitudeDegrees: position.latitudeDegrees,
                                   longitudeDegrees: position.longitudeDegrees,
                                   zoom: position.zoom,
                                   bearing: bearingLimits.clamped(position.bearing),
                                   pitch: pitchLimits.clamped(position.pitch))
    }

    public static func normalizedBearing(_ bearing: Float) -> Float {
        let twoPi = Float.pi * 2
        var normalized = (bearing + .pi).truncatingRemainder(dividingBy: twoPi)
        if normalized < 0 {
            normalized += twoPi
        }
        return normalized - .pi
    }
}

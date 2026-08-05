// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// How the camera frames the point it is following along a path.
public struct ImmersiveMapCameraFollowOptions: Equatable, Sendable {
    /// Where the camera looks while it travels.
    public enum Bearing: Equatable, Sendable {
        /// Turn to the trajectory, so the direction of travel points up the
        /// screen. On a zoomed-out globe the engine limits how far the camera
        /// may rotate (`CameraSettings.globeBearingUnlockZoom`), so the turn is
        /// clamped there rather than fought for.
        case course
        /// Keep whatever bearing the camera already has.
        case unchanged
        /// Hold a fixed bearing, clockwise from north, in radians.
        case fixed(Float)
    }

    public static let `default` = ImmersiveMapCameraFollowOptions()

    /// nil keeps the camera's current zoom, so the app can zoom while
    /// following without the follow fighting back.
    public var zoom: Double?
    /// nil keeps the camera's current pitch, in radians.
    public var pitch: Float?
    public var bearing: Bearing
    /// Half-life of the exponential catch-up, in seconds: the camera trails the
    /// point and closes half the remaining gap every `smoothingHalfLife`. Zero
    /// pins the camera exactly on it, which reads as rigid on a curved path.
    public var smoothingHalfLife: Double

    public init(zoom: Double? = nil,
                pitch: Float? = nil,
                bearing: Bearing = .course,
                smoothingHalfLife: Double = 0.35) {
        self.zoom = zoom
        self.pitch = pitch
        self.bearing = bearing
        self.smoothingHalfLife = smoothingHalfLife
    }
}

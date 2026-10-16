// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The animated zoom: the camera's zoom followed over time rather than
/// read, closing half of what is left every half-life
/// (`ImmersiveMapSettings.CameraSettings.animatedZoomHalfLife`). The
/// camera's own zoom is the fact of the frame, and the tiles, the rings
/// and the camera's pose read it as it is. What dresses the frame by the
/// zoom (the styles' zoom fades, the labels' reach) reads
/// this one (`FrameContext.animatedZoom`), and the relief's collapse reads a
/// zoom held through a drag and then followed the same way
/// (`RenderFrameEngine`), so a zoom
/// that jumps in one frame, as it does when the point the camera looks at
/// drops off a ridge onto the plain below and the arm lengthens at once
/// (`CameraTerrainFollow`), dresses the frame over a few frames instead.
/// A camera set outright (`FrameCameraStateResolver.cameraJumpCount`)
/// snaps it, so a teleport across the world is not dressed as a flight.
struct AnimatedZoom {
    /// The zoom as it stands, nil before the first frame.
    private(set) var value: Double?
    /// Whether the zoom is still on its way to the camera's: the frames
    /// keep coming while it is (`RenderActivityState`).
    private(set) var isSettling = false

    /// How close the zoom gets before it is the camera's: a thousandth of
    /// a level, under anything a fade could show.
    static let settledTolerance = 0.001

    /// Moves the zoom toward `zoom` by `deltaTime` seconds and returns it.
    /// `snap`, a half-life of zero or less, or the first frame set it to
    /// `zoom` at once.
    mutating func advance(toward zoom: Double, deltaTime: Double, halfLife: Double, snap: Bool = false) -> Double {
        guard let current = value, snap == false, halfLife > 0, zoom.isFinite else {
            value = zoom
            isSettling = false
            return zoom
        }
        let remaining = zoom - current
        guard abs(remaining) > Self.settledTolerance else {
            value = zoom
            isSettling = false
            return zoom
        }
        let share = deltaTime > 0 ? 1 - pow(0.5, deltaTime / halfLife) : 0
        let next = current + remaining * share
        value = next
        isSettling = abs(zoom - next) > Self.settledTolerance
        if isSettling == false {
            value = zoom
            return zoom
        }
        return next
    }
}

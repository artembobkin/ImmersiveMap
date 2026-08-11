// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// How one still of the map is rendered.
public struct ImmersiveMapStillConfiguration: Equatable, Sendable {
    public static let `default` = ImmersiveMapStillConfiguration()

    /// Output width in pixels. Within 1...16384.
    public var width: Int
    /// Output height in pixels. Within 1...16384.
    public var height: Int

    /// Drawable pixels per layout point, the same number a screen reports as
    /// its scale.
    ///
    /// It is not a size multiplier: `width` and `height` are already the pixel
    /// dimensions. It tells the renderer how big a point is, which is what
    /// style values expressed in points (label sizes, route widths, marker
    /// halos) are measured against. Capturing at 1 renders a 1024 pixel image
    /// with labels sized for a 1024 point canvas; capturing at 2 renders the
    /// same image with labels sized for a 512 point canvas, which is what a
    /// Retina screen of that width would show.
    public var pixelsPerPoint: CGFloat

    /// How long the capture may wait for outstanding tiles before the frame is
    /// taken with whatever has loaded.
    ///
    /// A still has no next frame to correct itself, so this matters more than
    /// it does for video: at zero the capture returns the first frame, which
    /// on a cold cache is an empty map.
    public var tileReadinessTimeout: TimeInterval

    /// Wall date used for the earth scene, meaning the sun position and the
    /// night side. `nil` uses the moment the capture starts, which makes the
    /// image depend on when it was taken; pin it for reproducible output.
    public var sceneDate: Date?

    public init(width: Int = 1920,
                height: Int = 1080,
                pixelsPerPoint: CGFloat = 2,
                tileReadinessTimeout: TimeInterval = 10,
                sceneDate: Date? = nil) {
        self.width = width
        self.height = height
        self.pixelsPerPoint = pixelsPerPoint
        self.tileReadinessTimeout = tileReadinessTimeout
        self.sceneDate = sceneDate
    }

    /// - Throws: ``ImmersiveMapStillCaptureError/invalidConfiguration(_:)``
    ///   naming the first field that is out of range.
    public func validate() throws {
        guard (1...16384).contains(width) else {
            throw ImmersiveMapStillCaptureError.invalidConfiguration("width must be within 1...16384")
        }
        guard (1...16384).contains(height) else {
            throw ImmersiveMapStillCaptureError.invalidConfiguration("height must be within 1...16384")
        }
        guard pixelsPerPoint > 0, pixelsPerPoint <= 8 else {
            throw ImmersiveMapStillCaptureError
                .invalidConfiguration("pixelsPerPoint must be greater than 0 and at most 8")
        }
        guard tileReadinessTimeout >= 0 else {
            throw ImmersiveMapStillCaptureError.invalidConfiguration("tileReadinessTimeout must not be negative")
        }
    }
}

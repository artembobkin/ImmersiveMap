// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMap

/// Avatar geometry is measured in drawable pixels. The map is not.
///
/// The renderer sizes a marker as `AvatarSettings.size * sizeScale` pixels, and
/// the collision solver measures everything around it in the same pixels: the
/// grouping radius that forms a flower, the spring offset a displaced marker is
/// allowed, the ring a petal sits on. None of it is scaled by the drawable's
/// pixel density. The map underneath works the other way: the engine puts
/// roughly `1.06 * frameHeight * 2^zoom` pixels across the world
/// (`ZoomAnchorMath`), so the ground scale grows with the frame.
///
/// Together those two rules mean a marker of a fixed pixel size covers half as
/// much ground in a 2160-tall frame as in a 1080-tall one. Left alone, that
/// makes the storyboard resolution-dependent in the one way this post cannot
/// afford: the zoom that packs the crowd into a single flower at 1080p leaves
/// it as loose singles at 4K, and the bloom the video is named after would
/// happen at a different second in every format.
///
/// So the pixel-valued avatar settings are derived from the height of the frame
/// being rendered instead of being written down once. The crowd then reaches
/// each stage of the layout at the same zoom, and therefore at the same second,
/// in the preview window, in 1080p, in 4K, and in the vertical cut.
enum CrowdScale {
    /// Marker height as a fraction of the frame height.
    ///
    /// At 10.5% a portrait is large enough to be a face rather than a dot in a
    /// wide shot, and small enough that fifty of them do not paper over the
    /// Eixample in the street shot.
    static let markerHeightFraction = 0.105

    /// The frame the other numbers are quoted at, and the height the defaults
    /// in `ImmersiveMapSettings.AvatarSettings` were picked for.
    static let referenceHeightPx = 1080.0

    /// Atlas cell size. Fixed rather than derived: it is the source resolution
    /// of the portraits, not a screen measurement, and 256 covers the largest
    /// marker the post draws (226 px in a 4K frame).
    static let size = ImmersiveMapSettings.AvatarSettings.Size.px256

    static func sizeScale(frameHeightPx: Double) -> Float {
        Float(markerHeightFraction * frameHeightPx / Double(size.rawValue))
    }

    /// How far a marker may be pushed off its geo point before the layout gives
    /// up and lets it overlap. Scaled with the frame so a displaced marker
    /// travels the same distance over the ground in every format.
    static func maxOffsetPx(frameHeightPx: Double) -> Float {
        Float(220.0 * frameHeightPx / referenceHeightPx)
    }

    /// The white ring around a portrait. Scaled for the same reason a marker
    /// is: a 3 px ring drawn around a 226 px marker in 4K is a hairline that
    /// the video codec eats.
    static func borderWidthPx(frameHeightPx: Double) -> Float {
        Float(3.4 * frameHeightPx / referenceHeightPx)
    }
}

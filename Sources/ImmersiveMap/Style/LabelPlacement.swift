// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Where a point label is drawn.
public enum LabelPlacement: Hashable, Sendable {
    /// Upright on the screen at its style's point size, whatever the
    /// camera does, and placed among the other labels by the collisions.
    case screen
    /// Painted on the map itself: the text lies on the ground, turns and
    /// tilts with it, curves with the globe, and grows and shrinks with
    /// the zoom like the geometry around it. It takes no part in the
    /// collisions, and the screen labels draw over it. Suited to the name
    /// of a large area, an ocean, a sea or a lake.
    case surface(SurfaceLabelPlacement)
}

/// How a label painted on the map scales and when it shows.
public struct SurfaceLabelPlacement: Hashable, Sendable {
    /// The camera zoom from which the text grows with the map: there it is
    /// as large on screen as its style's point size, one zoom deeper twice
    /// as large. It never draws smaller than that size, so under this zoom,
    /// and wherever the ground itself is small on screen (the globe near a
    /// pole), it keeps its point size and stays readable.
    public var referenceZoom: Double
    /// The camera zooms the text shows at, whole: it appears and goes away
    /// at the ends without a fade.
    public var minimumZoom: Double
    public var maximumZoom: Double
    /// Extra room after every letter, in ems: a name spaced out over the
    /// area it names, the way an atlas letters a sea.
    public var letterSpacingEm: Float

    public init(referenceZoom: Double,
                minimumZoom: Double = -.infinity,
                maximumZoom: Double = .infinity,
                letterSpacingEm: Float = 0) {
        self.referenceZoom = referenceZoom
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.letterSpacingEm = letterSpacingEm
    }

    /// Whether the text shows at a camera zoom.
    func isVisible(atZoom zoom: Double) -> Bool {
        zoom >= minimumZoom && zoom < maximumZoom
    }

    /// Whether a tile of this zoom ever shows the text. The engine draws a
    /// tile for the camera zooms from its own zoom up to the next.
    func isVisible(onTileZoom tileZoom: Int) -> Bool {
        let lowest = Double(tileZoom)
        return lowest + 1 > minimumZoom && lowest < maximumZoom
    }
}

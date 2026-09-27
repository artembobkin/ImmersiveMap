// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The sign a route number is drawn on: its outline, its colours and the
/// colour of the number. The shapes are drawn by the shader from their
/// distance fields, so a sign costs one quad and no image, at any size.
public struct RouteShieldAppearance: Hashable, Sendable {
    public enum Shape: UInt8, Hashable, Sendable {
        /// A rectangle with corners rounded by `cornerRadiusEm`: the plate
        /// most countries number their roads on.
        case rectangle = 0
        /// A rectangle with fully round ends.
        case capsule = 1
        /// A heraldic shield: a flat top, straight sides, and a bottom that
        /// comes to a point. The United States' Interstate and US highway
        /// signs.
        case escutcheon = 2
    }

    public var shape: Shape
    public var fillColor: SIMD3<Float>
    public var textColor: SIMD3<Float>
    public var borderColor: SIMD3<Float>
    /// The width of the border inside the outline, as a fraction of the
    /// em. Zero draws none.
    public var borderEm: Float
    /// The corner radius of a `rectangle` (and of an `escutcheon`'s top
    /// corners), as a fraction of the em.
    public var cornerRadiusEm: Float
    /// The room between the number and each side of the sign, as a
    /// fraction of the em. A sign is never narrower than it is tall.
    public var paddingEm: Float
    /// A band across the top of the sign in its own colour (the red crown
    /// of an Interstate sign), nil for a sign in one colour. The number
    /// sits in the part below it.
    public var headerColor: SIMD3<Float>?
    /// The band's height as a fraction of the sign's.
    public var headerFraction: Float

    public init(shape: Shape = .rectangle,
                fillColor: SIMD3<Float>,
                textColor: SIMD3<Float>,
                borderColor: SIMD3<Float>? = nil,
                borderEm: Float = 0,
                cornerRadiusEm: Float = 0.2,
                paddingEm: Float = 0.35,
                headerColor: SIMD3<Float>? = nil,
                headerFraction: Float = 0.25) {
        self.shape = shape
        self.fillColor = fillColor
        self.textColor = textColor
        self.borderColor = borderColor ?? fillColor
        self.borderEm = max(0, borderEm)
        self.cornerRadiusEm = max(0, cornerRadiusEm)
        self.paddingEm = max(0, paddingEm)
        self.headerColor = headerColor
        self.headerFraction = min(max(headerFraction, 0), 0.5)
    }
}

/// One route's sign: the number and what it is drawn on.
public struct RouteShield: Hashable, Sendable {
    public var text: String
    public var appearance: RouteShieldAppearance

    public init(text: String, appearance: RouteShieldAppearance) {
        self.text = text
        self.appearance = appearance
    }
}

/// The route signs a road carries: the numbers of the routes it is part of,
/// each on its own sign, side by side, upright on the screen whatever way
/// the road runs, and repeated along the road. They take part in the label
/// collisions as one label.
///
/// The style decides the signs from the road's facts
/// (`ImmersiveMapRoadFacts.routes`): which routes are signed, in which
/// order, and on which sign. The engine draws what it is given.
public struct RouteShieldStyle: Sendable {
    /// The signs, left to right. Empty draws nothing.
    public var shields: [RouteShield]
    /// The em size of the numbers in layout points. The sign is sized from
    /// it.
    public var sizePoints: Float
    public var weight: LabelFontWeight
    /// The height of a sign as a fraction of the em. An `escutcheon` is
    /// drawn a fifth taller, and at least as tall as it is wide, so its
    /// point has room below the number.
    public var plateHeightEm: Float
    /// The room between two signs side by side, as a fraction of the em.
    public var gapEm: Float
    /// The least distance, in layout points at the tile's own zoom, between
    /// two copies of the same signs along the roads of a tile. A road
    /// shorter than that inside a tile carries one copy.
    public var spacingPoints: Float
    /// The signs' importance among the labels, lower first, as a point
    /// label's `rank`.
    public var rank: Int
    /// The signs' precedence when they overlap another label, lower wins,
    /// as a point label's `collisionRank`.
    public var collisionRank: Int
    /// Minimum camera zoom for the signs (0 = always visible).
    public var minCameraZoom: Float

    public init(shields: [RouteShield],
                sizePoints: Float = 11,
                weight: LabelFontWeight = .bold,
                plateHeightEm: Float = 1.45,
                gapEm: Float = 0.25,
                spacingPoints: Float = 200,
                rank: Int = 0,
                collisionRank: Int? = nil,
                minCameraZoom: Float = 0) {
        self.shields = shields
        self.sizePoints = sizePoints
        self.weight = weight
        self.plateHeightEm = max(0, plateHeightEm)
        self.gapEm = max(0, gapEm)
        self.spacingPoints = max(0, spacingPoints)
        self.rank = rank
        self.collisionRank = collisionRank ?? rank
        self.minCameraZoom = minCameraZoom
    }
}

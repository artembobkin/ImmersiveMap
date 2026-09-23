// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A decoration the separate-road path stamps along a line on top of its
/// ribbon. Every figure's dimensions are the style's: each case carries
/// them, with the defaults the built-in style draws with.
public enum RoadDecorationKind: Equatable, Sendable {
    case none
    /// Arrows along a one-way road, in the paint stroke.
    case onewayArrow(OnewayArrowDecoration = OnewayArrowDecoration())
}

/// The arrows along a one-way road, in tile units: how far apart they
/// repeat, the shortest fragment that carries one, and the turn an arrow
/// keeps clear of.
public struct OnewayArrowDecoration: Equatable, Sendable {
    /// The distance between arrows along the road, in tile units.
    public var repeatStep: Float
    /// A fragment shorter than this, or than the stroke width times
    /// `minimumFragmentLengthFactor`, carries no arrow.
    public var minimumFragmentLength: Float
    public var minimumFragmentLengthFactor: Float
    /// An arrow within its own length of a turn sharper than this is not
    /// placed.
    public var turnThresholdRadians: Float

    public init(repeatStep: Float = 420.0,
                minimumFragmentLength: Float = 96.0,
                minimumFragmentLengthFactor: Float = 4.5,
                turnThresholdRadians: Float = .pi / 4.0) {
        self.repeatStep = repeatStep
        self.minimumFragmentLength = minimumFragmentLength
        self.minimumFragmentLengthFactor = minimumFragmentLengthFactor
        self.turnThresholdRadians = turnThresholdRadians
    }
}

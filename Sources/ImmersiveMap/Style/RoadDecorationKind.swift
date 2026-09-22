// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A decoration the separate-road path stamps along a line or over a
/// surface instead of, or on top of, its ribbon. Every figure's
/// dimensions are the style's: each case carries them, with the defaults
/// the built-in style draws with.
public enum RoadDecorationKind: Equatable, Sendable {
    case none
    /// Arrows along a one-way road, in the paint stroke.
    case onewayArrow(OnewayArrowDecoration = OnewayArrowDecoration())
    /// A marked crossing: white stripes laid across the carriageway, over
    /// the band the paint stroke's width states.
    case zebraCrossing(ZebraCrossingDecoration = ZebraCrossingDecoration())
    /// A parking area polygon whose paint stroke is the synthesized comb
    /// of parking-bay stripes (see `ParkingBayGeometryBuilder`).
    case parkingBays(ParkingBaysDecoration = ParkingBaysDecoration())
    /// A bus lane axis whose paint stroke is the letter A stamped along
    /// the lane (see `BusLaneLetterGeometryBuilder`).
    case busLaneLetter(BusLaneLetterDecoration = BusLaneLetterDecoration())
    /// A bus stop's stretch of kerb, folded into the yellow sawtooth (see
    /// `BusStopZigzagGeometryBuilder`).
    case busStopZigzag(BusStopZigzagDecoration = BusStopZigzagDecoration())
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

/// The dimensions of a zebra, in tile units, derived from the band the
/// paint stroke states: the stripe step is the band divided by
/// `stripeStepDivisor` (floored at `minimumStripeStep`), the stripe fills
/// `stripeFillFactor` of its step, and the figure is inset from each end
/// of the crossing by `endInsetFactor` of its length.
public struct ZebraCrossingDecoration: Equatable, Sendable {
    public var minimumCrossingLength: Float
    public var minimumStripeWidth: Float
    public var stripeFillFactor: Float
    public var stripeStepDivisor: Float
    public var minimumStripeStep: Float
    public var endInsetFactor: Float

    public init(minimumCrossingLength: Float = 2.0,
                minimumStripeWidth: Float = 2.0,
                stripeFillFactor: Float = 0.72,
                stripeStepDivisor: Float = 5.0,
                minimumStripeStep: Float = 3.0,
                endInsetFactor: Float = 0.05) {
        self.minimumCrossingLength = minimumCrossingLength
        self.minimumStripeWidth = minimumStripeWidth
        self.stripeFillFactor = stripeFillFactor
        self.stripeStepDivisor = stripeStepDivisor
        self.minimumStripeStep = minimumStripeStep
        self.endInsetFactor = endInsetFactor
    }
}

/// The layout of a parking lot's comb, in metres on the ground. The long
/// axis of the polygon's minimum-area bounding rectangle is the driving
/// direction; bays run across it. A shallow strip (up to
/// `singleRowMaximumDepthMetres`) gets one row of stripes across its whole
/// depth; a deeper lot alternates a bay row and a driving aisle.
public struct ParkingBaysDecoration: Equatable, Sendable {
    /// A bay's width; parallel parking spaces are `parallelStepMetres`
    /// apart instead.
    public var bayStepMetres: Float
    public var parallelStepMetres: Float
    /// One row of bays reaches this far from the kerb; the aisle between
    /// two rows is bare asphalt.
    public var rowDepthMetres: Float
    public var aisleDepthMetres: Float
    public var singleRowMaximumDepthMetres: Float
    /// A row cut shorter than this by the polygon edge is dropped.
    public var minimumRowDepthMetres: Float
    /// A stripe piece shorter than this is a corner sliver, not a divider.
    public var minimumStripeMetres: Float

    public init(bayStepMetres: Float = 2.6,
                parallelStepMetres: Float = 6.0,
                rowDepthMetres: Float = 5.0,
                aisleDepthMetres: Float = 6.0,
                singleRowMaximumDepthMetres: Float = 8.0,
                minimumRowDepthMetres: Float = 2.5,
                minimumStripeMetres: Float = 1.8) {
        self.bayStepMetres = bayStepMetres
        self.parallelStepMetres = parallelStepMetres
        self.rowDepthMetres = rowDepthMetres
        self.aisleDepthMetres = aisleDepthMetres
        self.singleRowMaximumDepthMetres = singleRowMaximumDepthMetres
        self.minimumRowDepthMetres = minimumRowDepthMetres
        self.minimumStripeMetres = minimumStripeMetres
    }
}

/// The letter A along a bus lane, in metres on the ground: its height,
/// half its width at the feet, its stroke, where the crossbar sits up the
/// legs, how far apart the letters repeat and how far from the lane's
/// ends the first and last stand.
public struct BusLaneLetterDecoration: Equatable, Sendable {
    public var letterHeightMetres: Float
    public var letterHalfWidthMetres: Float
    public var strokeMetres: Float
    public var crossbarFraction: Float
    public var repeatStepMetres: Float
    public var endInsetMetres: Float

    public init(letterHeightMetres: Float = 2.6,
                letterHalfWidthMetres: Float = 0.9,
                strokeMetres: Float = 0.4,
                crossbarFraction: Float = 0.32,
                repeatStepMetres: Float = 30.0,
                endInsetMetres: Float = 3.0) {
        self.letterHeightMetres = letterHeightMetres
        self.letterHalfWidthMetres = letterHalfWidthMetres
        self.strokeMetres = strokeMetres
        self.crossbarFraction = crossbarFraction
        self.repeatStepMetres = repeatStepMetres
        self.endInsetMetres = endInsetMetres
    }
}

/// The sawtooth along a bus stop's kerb, in metres on the ground: one
/// tooth per period, swaying by the amplitude to each side, in a stroke
/// of the given width.
public struct BusStopZigzagDecoration: Equatable, Sendable {
    public var toothPeriodMetres: Float
    public var amplitudeMetres: Float
    public var strokeMetres: Float

    public init(toothPeriodMetres: Float = 2.4,
                amplitudeMetres: Float = 0.6,
                strokeMetres: Float = 0.35) {
        self.toothPeriodMetres = toothPeriodMetres
        self.amplitudeMetres = amplitudeMetres
        self.strokeMetres = strokeMetres
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A decoration the separate-road path stamps along a line or over a
/// surface instead of, or on top of, its ribbon.
public enum RoadDecorationKind: Sendable {
    case none
    case onewayArrow
    case zebraCrossing
    /// A parking area polygon whose detail pass is the synthesized comb
    /// of parking-bay stripes (see `ParkingBayGeometryBuilder`).
    case parkingBays
    /// A bus lane axis whose detail pass is the letter A stamped along
    /// the lane (see `BusLaneLetterGeometryBuilder`).
    case busLaneLetter
    /// A bus stop axis whose detail pass is the yellow sawtooth along
    /// the kerb (see `BusStopZigzagGeometryBuilder`).
    case busStopZigzag
}

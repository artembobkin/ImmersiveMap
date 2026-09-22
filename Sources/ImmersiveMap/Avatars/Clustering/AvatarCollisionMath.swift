// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  AvatarCollisionMath.swift
//  ImmersiveMap
//

import Foundation
import simd

/// Stateless math for Zenly-style avatar placement: smoothing factor,
/// anchor density pressure, compression targets, and fallback separation
/// directions for coincident centers.
enum AvatarCollisionMath {
    /// The offset is considered converged when it is closer to the target than this threshold.
    static let offsetSnapEpsilonPx: Float = 0.5
    /// Scale/morph are considered converged at this proximity to the target.
    static let scaleSnapEpsilon: Float = 0.01
    /// Fraction of marker size: anchor sticking radius for overflow grouping.
    static let groupingRadiusScale: Float = 0.35
    /// Sticking-radius expansion for already grouped markers (hysteresis).
    static let groupingHysteresisRatio: Float = 1.3
    /// Crossfade duration for markers <-> cluster icon.
    static let clusterCrossfadeSeconds: Float = 0.25
    /// Cap on the per-frame time step: guards against jumps after pauses.
    static let maxFrameDeltaSeconds: TimeInterval = 0.25
    /// Compression scale below which badges are fully hidden.
    static let badgeFadeStartScale: Float = 0.8
    /// Compression scale at and above which badges are fully visible.
    static let badgeFadeEndScale: Float = 0.95
    /// Fraction of body radius: deterministic starting jitter of nodes. Breaks
    /// degenerate configurations (collinear anchors would separate strictly
    /// along a single line and never fan out).
    static let startJitterScale: Float = 0.05
    /// A solved offset below this threshold is treated as zero: cancels the
    /// starting-jitter residue on solitary markers.
    static let restSnapRadiusPx: Float = 1.5
    /// Salt for the starting-jitter direction.
    static let startJitterSalt: UInt64 = 0x517cc1b727220a95

    /// Fraction of the path toward the target per frame for exponential smoothing,
    /// normalized to the frame duration (fps-independent).
    static func smoothingFactor(smoothing: Float, deltaSeconds: TimeInterval) -> Float {
        let clamped = simd_clamp(smoothing, 0.0, 1.0)
        guard deltaSeconds > 0 else {
            return 0.0
        }
        return 1.0 - pow(1.0 - clamped, Float(deltaSeconds * 60.0))
    }

    /// Deterministic separation direction for a pair of nodes whose centers
    /// coincide and whose collision normal is undefined.
    static func stableUnitDirection(idA: UInt64, idB: UInt64) -> SIMD2<Float> {
        var hash: UInt64 = 0xcbf29ce484222325
        for id in [min(idA, idB), max(idA, idB)] {
            var value = id
            for _ in 0..<8 {
                hash ^= UInt64(UInt8(truncatingIfNeeded: value))
                hash &*= 0x100000001b3
                value >>= 8
            }
        }
        let angle = Float(hash % 6283) * 0.001
        return SIMD2<Float>(cos(angle), sin(angle))
    }

    /// Base scale of a displaced circle: the circle is always noticeably smaller than the pin.
    /// Under crowding the circle shrinks further, but never below compressedScale.
    static let displacedCircleScale: Float = 0.7

    /// Mutual body penetration depth at which the touch counts as full
    /// for the static shape check.
    static let staticTouchDepthPx: Float = 8.0

    /// Morph based on actual touch: the full marker body at its anchor versus
    /// the actual (already shrunken) bodies of neighbors. While there is no
    /// visible touch, the marker does not react - a neighbor circle does not
    /// "push" from a distance.
    static func staticTouchMorph(overlapDepth: Float) -> Float {
        smoothstep(edge0: 0.0, edge1: staticTouchDepthPx, x: overlapDepth)
    }

    /// Shape-based scale upper bound: a pin - full size, a displaced
    /// circle - no more than displacedCircleScale.
    static func scaleCap(morph: Float) -> Float {
        1.0 + (displacedCircleScale - 1.0) * simd_clamp(morph, 0.0, 1.0)
    }

    /// The scale at which a pair of bodies stops intersecting at the given
    /// distance; the compression is forced and split evenly between both bodies.
    /// `otherIsRigid` - the neighbor does not shrink (selected or a flower):
    /// the entire shortfall of space falls on the current marker.
    static func requiredScale(distance: Float,
                              bodyRadius: Float,
                              otherBodyRadius: Float,
                              padding: Float,
                              otherIsRigid: Bool) -> Float {
        let available = distance - 2.0 * padding
        guard bodyRadius > 0.0 else {
            return 1.0
        }
        let scale: Float
        if otherIsRigid {
            scale = (available - otherBodyRadius) / bodyRadius
        } else {
            scale = available / (bodyRadius + otherBodyRadius)
        }
        return simd_clamp(scale, 0.0, 1.0)
    }

    /// Maximum petals in a cluster flower; members that do not fit are hidden.
    static let maxFlowerPetals = 7

    /// A cluster must be local: the spread of its members' screen anchors
    /// must not exceed this multiple of the marker size. Oversized components
    /// (percolation of grouping chains on a dense field) are cut by the world
    /// grid, and ring merges that would violate the limit are forbidden.
    static let flowerCompactnessLimitScale: Float = 2.5

    /// Radius of the flower slot ring: adjacent petals touch each other.
    static func flowerRingRadius(petalBodyRadius: Float, petalCount: Int) -> Float {
        guard petalCount > 1 else {
            return 0.0
        }
        return petalBodyRadius / sin(.pi / Float(petalCount))
    }

    /// Petal position on the flower ring; the first petal is at the top.
    static func flowerPetalOffset(index: Int, petalCount: Int, ringRadius: Float) -> SIMD2<Float> {
        guard petalCount > 0 else {
            return .zero
        }
        let angle = Float.pi / 2.0 + 2.0 * .pi * Float(index) / Float(petalCount)
        return SIMD2<Float>(cos(angle), sin(angle)) * ringRadius
    }

    /// Offset at which a displaced marker starts turning into a circle.
    static let displacedMorphStartPx: Float = 2.0
    /// Offset at which the marker fully turns into a circle with a beam.
    static let displacedMorphEndPx: Float = 10.0

    /// Pin -> circle shape morph: a marker keeps the pin shape only while
    /// standing exactly on its geo point; any marker displaced by neighbors
    /// becomes a circle.
    static func displacedMorph(offsetLength: Float) -> Float {
        smoothstep(edge0: displacedMorphStartPx, edge1: displacedMorphEndPx, x: offsetLength)
    }

    /// Badge alpha: as the marker compresses, badges fade out smoothly.
    static func badgeContentAlpha(displayScale: Float) -> Float {
        smoothstep(edge0: badgeFadeStartScale, edge1: badgeFadeEndScale, x: displayScale)
    }

    static func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = simd_clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)
    }
}

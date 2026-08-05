// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Turns tessellated path samples into world-space centerline points for the
/// current frame. The sphere-plane morph is resolved here, on the CPU, through
/// the same `GeoSurfaceFrameMath` that anchors 3D models, so a model animated
/// along a path rides exactly on the drawn line.
///
/// Globe presentation only: the flat branch is deliberately not built yet.
enum RouteWorldGeometryBuilder {
    /// One centerline point: `xyz` is the world position, `w` is the position
    /// along the path by arc length.
    typealias Point = SIMD4<Float>

    static func build(samples: [GeoPathSample],
                      progress: Double,
                      constants: GeoScreenProjectionMath.FrameConstants) -> [Point] {
        guard constants.mode == .globe, samples.count >= 2 else { return [] }
        let clampedProgress = min(max(progress, 0), 1)
        guard clampedProgress > 0 else { return [] }

        // Truncating by progress on the CPU keeps the shader free of degenerate
        // triangles and gives the drawn end an exact position.
        let emitCount = samples.firstIndex { $0.fraction > clampedProgress } ?? samples.count
        guard emitCount >= 1 else { return [] }

        var points: [Point] = []
        points.reserveCapacity(emitCount + 1)
        var flatWorldXReference: Float?
        var lastWorldPosition = SIMD3<Float>(repeating: 0)

        for index in 0..<emitCount {
            let sample = samples[index]
            let frame = GeoSurfaceFrameMath.resolve(basis: sample.basis,
                                                    constants: constants,
                                                    flatWorldXReference: flatWorldXReference)
            flatWorldXReference = frame.flatWorldX
            lastWorldPosition = worldPosition(frame: frame, altitudeMeters: sample.altitudeMeters)
            points.append(Point(lastWorldPosition, Float(sample.fraction)))
        }

        // Partial last segment: the neighbours are at most a tessellation step
        // apart, so interpolating world positions is enough and re-slerping the
        // coordinate would buy nothing.
        if emitCount < samples.count {
            let previous = samples[emitCount - 1]
            let next = samples[emitCount]
            let span = next.fraction - previous.fraction
            // Progress landing exactly on a sample needs no extra point, and
            // duplicating it would emit a zero-length segment.
            if span > 0, clampedProgress > previous.fraction {
                let frame = GeoSurfaceFrameMath.resolve(basis: next.basis,
                                                        constants: constants,
                                                        flatWorldXReference: flatWorldXReference)
                let nextWorldPosition = worldPosition(frame: frame, altitudeMeters: next.altitudeMeters)
                let blend = Float((clampedProgress - previous.fraction) / span)
                let interpolated = lastWorldPosition + (nextWorldPosition - lastWorldPosition) * blend
                points.append(Point(interpolated, Float(clampedProgress)))
            }
        }

        return points.count >= 2 ? points : []
    }

    /// The same lift `SceneModelAnchorMath` applies to a model anchor.
    private static func worldPosition(frame: GeoSurfaceFrame, altitudeMeters: Double) -> SIMD3<Float> {
        frame.worldPosition + frame.up * (Float(altitudeMeters) * frame.unitsPerMeter)
    }
}

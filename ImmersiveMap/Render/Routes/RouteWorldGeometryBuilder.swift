// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The centerline of one route resolved for the current frame.
struct RouteWorldGeometry {
    /// `xyz` is the world position, `w` is the position along the path by arc
    /// length.
    let points: [SIMD4<Float>]
    /// Cumulative length of the projected centerline in drawable pixels,
    /// parallel to `points` and starting at 0. Dash patterns are measured in
    /// this space, so a dash keeps its size on screen at any zoom instead of
    /// stretching with the geometry.
    let screenLengthsPx: [Float]

    static let empty = RouteWorldGeometry(points: [], screenLengthsPx: [])

    var isEmpty: Bool {
        points.count < 2
    }
}

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

    /// Below this clip-space w a point is at or behind the near plane and its
    /// screen position is meaningless; the segment contributes no length.
    private static let minimumClipW: Float = 1e-4

    static func build(samples: [GeoPathSample],
                      progress: Double,
                      constants: GeoScreenProjectionMath.FrameConstants) -> RouteWorldGeometry {
        guard constants.mode == .globe, samples.count >= 2 else { return .empty }
        let clampedProgress = min(max(progress, 0), 1)
        guard clampedProgress > 0 else { return .empty }

        // Truncating by progress on the CPU keeps the shader free of degenerate
        // triangles and gives the drawn end an exact position.
        let emitCount = samples.firstIndex { $0.fraction > clampedProgress } ?? samples.count
        guard emitCount >= 1 else { return .empty }

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

        guard points.count >= 2 else { return .empty }
        return RouteWorldGeometry(points: points,
                                  screenLengthsPx: screenLengths(points: points, constants: constants))
    }

    /// Projects the centerline and accumulates its length in drawable pixels.
    /// Cheap enough to redo every frame (one matrix product per point) and the
    /// only way a dash can stay the same size on screen while the geometry
    /// behind it stretches with zoom.
    private static func screenLengths(points: [Point],
                                      constants: GeoScreenProjectionMath.FrameConstants) -> [Float] {
        let halfViewport = constants.viewport * 0.5
        var lengths: [Float] = []
        lengths.reserveCapacity(points.count)

        var accumulated: Float = 0
        var previousScreenPoint: SIMD2<Float>?
        for point in points {
            let clip = constants.cameraUniform.matrix * SIMD4<Float>(point.x, point.y, point.z, 1)
            guard clip.w > minimumClipW else {
                // Behind the near plane: the segment adds nothing and the chain
                // resumes from the next visible point.
                lengths.append(accumulated)
                previousScreenPoint = nil
                continue
            }
            let screenPoint = SIMD2<Float>(clip.x, clip.y) / clip.w * halfViewport
            if let previousScreenPoint {
                accumulated += simd_distance(previousScreenPoint, screenPoint)
            }
            previousScreenPoint = screenPoint
            lengths.append(accumulated)
        }
        return lengths
    }

    /// The same lift `SceneModelAnchorMath` applies to a model anchor.
    private static func worldPosition(frame: GeoSurfaceFrame, altitudeMeters: Double) -> SIMD3<Float> {
        frame.worldPosition + frame.up * (Float(altitudeMeters) * frame.unitsPerMeter)
    }
}

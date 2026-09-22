// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  SceneModelPickMath.swift
//  ImmersiveMap
//

import CoreGraphics
import simd

/// Ray geometry behind scene model hit-testing.
///
/// Scene models are rigid: `SceneModelAnchorMath` evaluates the sphere-to-plane
/// morph once per anchor and bakes it into a model matrix, and the vertex
/// shader is a plain `projectionView * modelMatrix * position`. So the same two
/// matrices invert into an exact picking ray, and a hit means the tap landed on
/// the model where it is drawn, in flat mode, on the globe, and mid-morph
/// alike. No approximation of the projection is involved, only of the mesh.
enum SceneModelPickMath {
    /// Degenerate input (a zero-scaled model, a point behind the camera)
    /// produces non-finite intermediates; every result is checked rather than
    /// trusted.
    private static let epsilon: Float = 1e-6

    struct Ray {
        let origin: SIMD3<Float>
        /// Unit length, so an intersection parameter is a render-space distance.
        let direction: SIMD3<Float>
    }

    /// The world-space ray under a screen point, given in drawable pixels with
    /// the origin bottom-left and y up: the convention `GeoScreenProjectionMath`
    /// projects into, inverted.
    ///
    /// The camera eye is the apex of the perspective frustum, so it is the
    /// exact ray origin, and one unprojected far-plane point fixes the
    /// direction.
    static func makeRay(pixelPoint: CGPoint,
                        drawSize: CGSize,
                        projectionView: matrix_float4x4,
                        cameraEye: SIMD3<Float>) -> Ray? {
        guard drawSize.width > 0,
              drawSize.height > 0 else {
            return nil
        }

        let normalizedDevice = SIMD2<Float>(Float(pixelPoint.x / drawSize.width) * 2.0 - 1.0,
                                            Float(pixelPoint.y / drawSize.height) * 2.0 - 1.0)
        let farClip = simd_inverse(projectionView) * SIMD4<Float>(normalizedDevice.x,
                                                                  normalizedDevice.y,
                                                                  1.0,
                                                                  1.0)
        guard farClip.w.isFinite,
              abs(farClip.w) > epsilon else {
            return nil
        }

        let delta = farClip.xyz / farClip.w - cameraEye
        let length = simd_length(delta)
        guard length.isFinite,
              length > epsilon else {
            return nil
        }

        return Ray(origin: cameraEye, direction: delta / length)
    }

    /// Distance from the ray origin to where it enters the model's bounding
    /// box, nil on a miss.
    ///
    /// The ray is carried into the model's own space instead of the box being
    /// carried out of it, which makes this an oriented-box test: an aircraft
    /// keeps a hit volume the shape of the aircraft rather than the bounding
    /// sphere's mostly empty ball. An affine transform preserves the ray
    /// parameter, so the returned distance is still in render-space units.
    static func intersectionDistance(ray: Ray,
                                     boundsMin: SIMD3<Float>,
                                     boundsMax: SIMD3<Float>,
                                     inverseModelMatrix: matrix_float4x4) -> Float? {
        let origin = (inverseModelMatrix * SIMD4<Float>(ray.origin, 1.0)).xyz
        let direction = (inverseModelMatrix * SIMD4<Float>(ray.direction, 0.0)).xyz

        var entry: Float = 0.0
        var exit: Float = .greatestFiniteMagnitude
        for axis in 0..<3 {
            // Parallel to this slab: the ray either runs inside it forever or
            // never enters it, and dividing would hand back an infinity.
            guard abs(direction[axis]) > epsilon else {
                guard origin[axis] >= boundsMin[axis],
                      origin[axis] <= boundsMax[axis] else {
                    return nil
                }
                continue
            }

            let inverseDirection = 1.0 / direction[axis]
            var near = (boundsMin[axis] - origin[axis]) * inverseDirection
            var far = (boundsMax[axis] - origin[axis]) * inverseDirection
            guard near.isFinite, far.isFinite else {
                return nil
            }
            if near > far {
                swap(&near, &far)
            }
            entry = max(entry, near)
            exit = min(exit, far)
            guard entry <= exit else {
                return nil
            }
        }

        // `entry` starts at zero, so a camera inside the box hits at distance 0
        // rather than behind itself.
        return entry
    }

    /// Screen rectangle spanned by the box's eight corners, in the same pixel
    /// convention as `makeRay`. nil when any corner sits behind the camera: the
    /// rectangle would be meaningless, and the only caller wants models small
    /// enough to be entirely in front.
    static func screenBounds(boundsMin: SIMD3<Float>,
                             boundsMax: SIMD3<Float>,
                             modelMatrix: matrix_float4x4,
                             projectionView: matrix_float4x4,
                             drawSize: CGSize) -> CGRect? {
        guard drawSize.width > 0,
              drawSize.height > 0 else {
            return nil
        }

        let clipMatrix = projectionView * modelMatrix
        let viewport = SIMD2<Float>(Float(drawSize.width), Float(drawSize.height))
        var minimum = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)

        for cornerIndex in 0..<8 {
            let corner = SIMD3<Float>(cornerIndex & 1 == 0 ? boundsMin.x : boundsMax.x,
                                      cornerIndex & 2 == 0 ? boundsMin.y : boundsMax.y,
                                      cornerIndex & 4 == 0 ? boundsMin.z : boundsMax.z)
            let clip = clipMatrix * SIMD4<Float>(corner, 1.0)
            guard clip.w > epsilon else {
                return nil
            }

            let screen = (SIMD2<Float>(clip.x, clip.y) / clip.w * 0.5 + 0.5) * viewport
            guard screen.x.isFinite,
                  screen.y.isFinite else {
                return nil
            }
            minimum = simd_min(minimum, screen)
            maximum = simd_max(maximum, screen)
        }

        return CGRect(x: CGFloat(minimum.x),
                      y: CGFloat(minimum.y),
                      width: CGFloat(maximum.x - minimum.x),
                      height: CGFloat(maximum.y - minimum.y))
    }

    /// Distance from the camera to the box center, the depth order used where
    /// there is no ray parameter to compare.
    static func distanceFromCamera(boundsMin: SIMD3<Float>,
                                   boundsMax: SIMD3<Float>,
                                   modelMatrix: matrix_float4x4,
                                   cameraEye: SIMD3<Float>) -> Float {
        let center = (boundsMin + boundsMax) * 0.5
        let worldCenter = (modelMatrix * SIMD4<Float>(center, 1.0)).xyz
        return simd_distance(worldCenter, cameraEye)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  SceneModelSelectionSnapshot.swift
//  ImmersiveMap
//

import CoreGraphics
import simd

/// One drawn model's hit volume: the model matrix the GPU drew it with, and the
/// asset-space box that matrix maps.
struct SceneModelSelectionEntry {
    let id: UInt64
    /// Where the model was drawn, carried through so a tap can report the
    /// position on screen rather than the descriptor's (mid-flight, different)
    /// destination.
    let coordinate: GeoCoordinate
    let modelMatrix: matrix_float4x4
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
}

/// Hit-test state of one rendered frame: every model that survived frustum
/// culling and the globe horizon gate, with the camera that drew them. What is
/// on screen is what can be tapped, and a model the frame skipped is not
/// tappable by construction.
struct SceneModelSelectionSnapshot {
    /// A model smaller than a fingertip cannot be aimed at. Below this size its
    /// hit area grows to a touch target, the platform minimum (HIG 44 pt).
    static let minimumTouchSizePoints: CGFloat = 44

    static let empty = SceneModelSelectionSnapshot(frameIndex: 0,
                                                   drawSize: .zero,
                                                   projectionView: matrix_identity_float4x4,
                                                   cameraEye: .zero,
                                                   entries: [])

    let frameIndex: UInt64
    let drawSize: CGSize
    /// World to clip of this frame, the matrix the scene model vertex shader
    /// was handed.
    let projectionView: matrix_float4x4
    let cameraEye: SIMD3<Float>
    let entries: [SceneModelSelectionEntry]

    /// The model under `point` (drawable pixels, origin bottom-left), nearest
    /// to the camera first. `minimumTouchSizePixels` <= 0 tests the geometry
    /// alone.
    func hitTest(point: CGPoint, minimumTouchSizePixels: CGFloat) -> SceneModelSelectionEntry? {
        guard entries.isEmpty == false,
              let ray = SceneModelPickMath.makeRay(pixelPoint: point,
                                                   drawSize: drawSize,
                                                   projectionView: projectionView,
                                                   cameraEye: cameraEye) else {
            return nil
        }

        var nearest: (entry: SceneModelSelectionEntry, distance: Float)?
        for entry in entries {
            guard let distance = SceneModelPickMath.intersectionDistance(
                ray: ray,
                boundsMin: entry.boundsMin,
                boundsMax: entry.boundsMax,
                inverseModelMatrix: simd_inverse(entry.modelMatrix)),
                distance < (nearest?.distance ?? .greatestFiniteMagnitude) else {
                continue
            }
            nearest = (entry, distance)
        }

        if let nearest {
            return nearest.entry
        }
        return touchTargetHit(point: point, minimumTouchSizePixels: minimumTouchSizePixels)
    }

    /// Fallback for models the geometry test missed: a model whose whole
    /// on-screen footprint is smaller than a touch target grows to one around
    /// its center. A model big enough to aim at never takes part, so this can
    /// only fill a gap and never steal a tap from geometry that was actually
    /// hit.
    private func touchTargetHit(point: CGPoint,
                                minimumTouchSizePixels: CGFloat) -> SceneModelSelectionEntry? {
        guard minimumTouchSizePixels > 0 else {
            return nil
        }

        var nearest: (entry: SceneModelSelectionEntry, distance: Float)?
        for entry in entries {
            guard let bounds = SceneModelPickMath.screenBounds(boundsMin: entry.boundsMin,
                                                               boundsMax: entry.boundsMax,
                                                               modelMatrix: entry.modelMatrix,
                                                               projectionView: projectionView,
                                                               drawSize: drawSize),
                  bounds.width <= minimumTouchSizePixels,
                  bounds.height <= minimumTouchSizePixels else {
                continue
            }

            let touchTarget = CGRect(x: bounds.midX - minimumTouchSizePixels * 0.5,
                                     y: bounds.midY - minimumTouchSizePixels * 0.5,
                                     width: minimumTouchSizePixels,
                                     height: minimumTouchSizePixels)
            guard touchTarget.contains(point) else {
                continue
            }

            let distance = SceneModelPickMath.distanceFromCamera(boundsMin: entry.boundsMin,
                                                                 boundsMax: entry.boundsMax,
                                                                 modelMatrix: entry.modelMatrix,
                                                                 cameraEye: cameraEye)
            guard distance < (nearest?.distance ?? .greatestFiniteMagnitude) else {
                continue
            }
            nearest = (entry, distance)
        }

        return nearest?.entry
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// What the frame needs to know about a label besides its geometry: its
/// key (the fades follow it across topology changes), whether it is a
/// duplicate of another visible label or belongs to a retained substitute
/// (both never shown), whether the slot holds a label at all, and the
/// camera zoom it appears from.
struct BaseLabelPresentationInput {
    static let empty = BaseLabelPresentationInput(labelKey: 0,
                                                  duplicate: 0,
                                                  isRetained: 0,
                                                  isValid: false,
                                                  minCameraZoom: 0)

    let labelKey: UInt64
    let duplicate: UInt8
    let isRetained: UInt8
    let isValid: Bool
    /// Minimum camera zoom at which the label is visible (0 = always).
    let minCameraZoom: Float
}

/// The per-label rules between the projection, the collision solve and the
/// fades, written as in-place passes so a frame allocates nothing.
enum BaseLabelVisibilityResolver {
    static let activeAlphaThreshold: Float = 0.0001

    /// Whether a label reserves collision space this frame: it must have a
    /// drawable screen point and be either in front of the horizon or still
    /// fading out behind it (so neighbours do not jump mid-fade), and a label
    /// below its minimum camera zoom reserves nothing while it is fully
    /// invisible, otherwise a zoom-hidden POI would displace visible ones.
    static func reservesSpace(candidateEnabled: Bool,
                              screenVisible: Bool,
                              horizonVisible: Bool,
                              currentAlpha: Float,
                              minCameraZoom: Float,
                              cameraZoom: Float) -> Bool {
        guard candidateEnabled, screenVisible else {
            return false
        }
        let active = horizonVisible || currentAlpha > activeAlphaThreshold
        let suppressedByZoom = minCameraZoom > cameraZoom && currentAlpha <= activeAlphaThreshold
        return active && suppressedByZoom == false
    }

    /// Whether a label wants to be shown: valid, not a duplicate, not a
    /// retained substitute's, accepted by the collision solve, in front of
    /// the horizon and at or above its minimum camera zoom.
    static func targetVisibility(inputs: [BaseLabelPresentationInput],
                                 collisionVisible: [Bool],
                                 horizonVisibility: [Bool],
                                 cameraZoom: Float,
                                 into target: inout [Bool]) {
        if target.count != inputs.count {
            target = [Bool](repeating: false, count: inputs.count)
        }
        for index in inputs.indices {
            let input = inputs[index]
            let accepted = index < collisionVisible.count && collisionVisible[index]
            let horizonVisible = index < horizonVisibility.count && horizonVisibility[index]
            target[index] = input.isValid &&
                input.duplicate == 0 &&
                input.isRetained == 0 &&
                accepted &&
                horizonVisible &&
                input.minCameraZoom <= cameraZoom
        }
    }
}

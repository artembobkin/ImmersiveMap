// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// What the frame needs to know about a label besides its geometry: its
/// key (the fades follow it across topology changes), whether it is a
/// duplicate of another visible label (never shown), whether the slot
/// holds a label at all, and the camera zoom it appears from.
struct BaseLabelPresentationInput {
    static let empty = BaseLabelPresentationInput(labelKey: 0,
                                                  duplicate: 0,
                                                  isValid: false,
                                                  minCameraZoom: 0)

    let labelKey: UInt64
    let duplicate: UInt8
    let isValid: Bool
    /// Minimum camera zoom at which the label is visible (0 = always).
    let minCameraZoom: Float
    /// Local detail, shown only near the camera (`LabelPlacementMeta.isLocal`).
    var isLocal: Bool = false
}

/// The per-label rules between the projection, the collision solve and the
/// fades, written as in-place passes so a frame allocates nothing.
enum BaseLabelVisibilityResolver {
    static let activeAlphaThreshold: Float = 0.0001

    /// Whether a label reserves collision space this frame: it must have a
    /// drawable screen point and be either in view (in front of the horizon
    /// and not behind a building) or still fading out of view (so
    /// neighbours do not jump mid-fade), and a label below its minimum
    /// camera zoom, or local detail outside the look-at tile
    /// (`localSuppressed`), reserves nothing while it is fully invisible,
    /// otherwise a hidden POI would displace visible ones.
    static func reservesSpace(candidateEnabled: Bool,
                              screenVisible: Bool,
                              horizonVisible: Bool,
                              occluded: Bool = false,
                              localSuppressed: Bool = false,
                              currentAlpha: Float,
                              minCameraZoom: Float,
                              cameraZoom: Float) -> Bool {
        guard candidateEnabled, screenVisible else {
            return false
        }
        let active = (horizonVisible && occluded == false) || currentAlpha > activeAlphaThreshold
        let suppressed = (minCameraZoom > cameraZoom || localSuppressed) && currentAlpha <= activeAlphaThreshold
        return active && suppressed == false
    }

    /// Whether a label wants to be shown: valid, not a duplicate, not a
    /// retained substitute's, accepted by the collision solve, in front of
    /// the horizon, not behind a building (`occluded`, a missing entry
    /// counts as in view), not local detail outside the look-at tile
    /// (`localSuppressed`, likewise) and at or above its minimum camera
    /// zoom.
    static func targetVisibility(inputs: [BaseLabelPresentationInput],
                                 collisionVisible: [Bool],
                                 horizonVisibility: [Bool],
                                 occluded: [Bool] = [],
                                 localSuppressed: [Bool] = [],
                                 cameraZoom: Float,
                                 into target: inout [Bool]) {
        if target.count != inputs.count {
            target = [Bool](repeating: false, count: inputs.count)
        }
        for index in inputs.indices {
            let input = inputs[index]
            let accepted = index < collisionVisible.count && collisionVisible[index]
            let horizonVisible = index < horizonVisibility.count && horizonVisibility[index]
            let hidden = index < occluded.count && occluded[index]
            let outsideLookAt = index < localSuppressed.count && localSuppressed[index]
            target[index] = input.isValid &&
                input.duplicate == 0 &&
                accepted &&
                horizonVisible &&
                hidden == false &&
                outsideLookAt == false &&
                input.minCameraZoom <= cameraZoom
        }
    }

    /// How far the local detail may be, for `localSuppression`.
    struct LocalDetailReach {
        /// The camera in the render world the anchors are placed in.
        let eye: SIMD3<Float>
        /// Render-world units per metre at the look-at point; nil where
        /// the distance is not measured (the globe), and the tiles alone
        /// decide.
        let unitsPerMeter: Float?
        let maximumDistanceMeters: Float
    }

    /// Which labels are local detail out of reach, written in place: a
    /// local label whose source tile lies outside the three by three
    /// tiles around the one holding the look-at point
    /// (`centerWorldMercator`, the map's normalized Mercator), counted in
    /// that tile's own grid, or whose anchor (`anchors`, xyz in the render
    /// world) is farther from the camera than `reach` allows. A tile
    /// coarser than the look-at tile holds the point over its whole area,
    /// so a stand-in shows its detail near the camera until the exact tiles
    /// arrive. Returns whether any label changed.
    @discardableResult
    static func localSuppression(inputs: [BaseLabelPresentationInput],
                                 pointInputs: [TilePointInput],
                                 anchors: [SIMD4<Float>],
                                 centerWorldMercator: SIMD2<Double>,
                                 reach: LocalDetailReach,
                                 into suppressed: inout [Bool]) -> Bool {
        if suppressed.count != inputs.count {
            suppressed = [Bool](repeating: false, count: inputs.count)
        }
        let maximumDistance = reach.unitsPerMeter.map { $0 * max(0, reach.maximumDistanceMeters) }
        var changed = false
        for index in inputs.indices {
            var outOfReach = false
            if inputs[index].isLocal, index < pointInputs.count {
                outOfReach = isWithinLookAtBlock(pointInputs[index].tile, mercator: centerWorldMercator) == false
                if outOfReach == false, let maximumDistance, index < anchors.count {
                    let anchor = anchors[index]
                    let distance = simd_length(SIMD3<Float>(anchor.x, anchor.y, anchor.z) - reach.eye)
                    outOfReach = distance > maximumDistance
                }
            }
            if suppressed[index] != outOfReach {
                suppressed[index] = outOfReach
                changed = true
            }
        }
        return changed
    }

    /// Whether the tile lies in the three by three tiles of its zoom around
    /// the one holding a point of the normalized Mercator world (x wrapped
    /// across the antimeridian, y clamped to the tile grid).
    static func isWithinLookAtBlock(_ tile: SIMD3<Int32>, mercator: SIMD2<Double>) -> Bool {
        let tilesCount = Int64(1) << Int64(tile.z)
        let lookAtX = Int64((ImmersiveMapProjection.wrapNormalizedWorldX(mercator.x) * Double(tilesCount)).rounded(.down))
        let lookAtY = Int64((ImmersiveMapProjection.clampNormalizedWorldY(mercator.y) * Double(tilesCount)).rounded(.down))
        let dx = abs(Int64(tile.x) - lookAtX)
        let dy = abs(Int64(tile.y) - lookAtY)
        return min(dx, tilesCount - dx) <= 1 && dy <= 1
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// What the frame needs to know about a label besides its geometry: its
/// key (the identity two copies of one feature share, and what the trace
/// names it by), the camera zoom it appears from, and whether it is local
/// detail. Every slot of the working set holds a label: the set is packed.
struct BaseLabelPresentationInput {
    let labelKey: UInt64
    /// Minimum camera zoom at which the label is visible (0 = always).
    let minCameraZoom: Float
    /// Local detail, shown only near the camera (`LabelPlacementMeta.isLocal`).
    var isLocal: Bool = false
    /// Another tile's copy of a feature the set keeps (`BaseLabelCache`):
    /// it never reserves space and never shows.
    var isCopy: Bool = false
}

/// The per-label rules between the projection, the collision solve and the
/// fades, written as in-place passes over raw buffers so a frame allocates
/// nothing and pays no per-element check.
enum BaseLabelVisibilityResolver {
    static let activeAlphaThreshold: Float = 0.0001

    /// Whether a label reserves collision space this frame: it must have a
    /// drawable screen point and be either in view (in front of the
    /// horizon) or still fading out of view (so
    /// neighbours do not jump mid-fade), and a label below its minimum
    /// camera zoom, or local detail outside the look-at tile
    /// (`localSuppressed`), reserves nothing while it is fully invisible,
    /// otherwise a hidden POI would displace visible ones.
    @inline(__always)
    static func reservesSpace(screenVisible: Bool,
                              horizonVisible: Bool,
                              localSuppressed: Bool = false,
                              currentAlpha: Float,
                              minCameraZoom: Float,
                              cameraZoom: Float) -> Bool {
        guard screenVisible else {
            return false
        }
        let active = horizonVisible || currentAlpha > activeAlphaThreshold
        let suppressed = (minCameraZoom > cameraZoom || localSuppressed) && currentAlpha <= activeAlphaThreshold
        return active && suppressed == false
    }

    /// `reservesSpace` for the whole set, written into `reserves`, which
    /// is sized to `inputs`. `localSuppressed` may be shorter than the set
    /// or empty: a missing entry counts as in view.
    /// A copy (`BaseLabelPresentationInput.isCopy`) reserves nothing.
    /// Only the labels of `spans` are decided (`LabelActiveSpans`), the
    /// rest reserve nothing. Nil decides every label.
    static func reservesSpace(inputs: [BaseLabelPresentationInput],
                              screenPoints: [ScreenPointOutput],
                              horizonVisibility: [Bool],
                              localSuppressed: [Bool],
                              currentAlphas: [Float],
                              cameraZoom: Float,
                              spans: [Range<Int>]? = nil,
                              into reserves: inout [Bool]) {
        let count = inputs.count
        if reserves.count != count {
            reserves = [Bool](repeating: false, count: count)
        }
        let spans = spans ?? [0..<count]
        let limit = min(count, min(screenPoints.count, min(horizonVisibility.count, currentAlphas.count)))
        inputs.withUnsafeBufferPointer { inputs in
        screenPoints.withUnsafeBufferPointer { screenPoints in
        horizonVisibility.withUnsafeBufferPointer { horizon in
        localSuppressed.withUnsafeBufferPointer { local in
        currentAlphas.withUnsafeBufferPointer { alphas in
        reserves.withUnsafeMutableBufferPointer { reserves in
            if let base = reserves.baseAddress {
                memset(base, 0, count * MemoryLayout<Bool>.stride)
            }
            let localCount = local.count
            for span in spans {
                var index = span.lowerBound
                let end = min(span.upperBound, limit)
                while index < end {
                    reserves[index] = inputs[index].isCopy == false && reservesSpace(screenVisible: screenPoints[index].visible != 0,
                                                    horizonVisible: horizon[index],
                                                    localSuppressed: index < localCount && local[index],
                                                    currentAlpha: alphas[index],
                                                    minCameraZoom: inputs[index].minCameraZoom,
                                                    cameraZoom: cameraZoom)
                    index += 1
                }
            }
        }}}}}}
    }

    /// Whether a label wants to be shown: accepted by the collision solve
    /// (which never offers a copy a place), in front of the
    /// horizon, not local detail outside the look-at tile
    /// (`localSuppressed`, likewise) and at or above its minimum camera
    /// zoom. A missing collision or horizon entry counts as hidden. Only
    /// the labels of `spans` are decided (`LabelActiveSpans`), the rest
    /// want to be hidden. Nil decides every label.
    static func targetVisibility(inputs: [BaseLabelPresentationInput],
                                 collisionVisible: [Bool],
                                 horizonVisibility: [Bool],
                                 localSuppressed: [Bool] = [],
                                 cameraZoom: Float,
                                 spans: [Range<Int>]? = nil,
                                 into target: inout [Bool]) {
        let count = inputs.count
        if target.count != count {
            target = [Bool](repeating: false, count: count)
        }
        let spans = spans ?? [0..<count]
        inputs.withUnsafeBufferPointer { inputs in
        collisionVisible.withUnsafeBufferPointer { collision in
        horizonVisibility.withUnsafeBufferPointer { horizon in
        localSuppressed.withUnsafeBufferPointer { local in
        target.withUnsafeMutableBufferPointer { target in
            if let base = target.baseAddress {
                memset(base, 0, count * MemoryLayout<Bool>.stride)
            }
            let collisionCount = collision.count
            let horizonCount = horizon.count
            let localCount = local.count
            for span in spans {
                var index = span.lowerBound
                let end = min(span.upperBound, count)
                while index < end {
                    let accepted = index < collisionCount && collision[index]
                    let horizonVisible = index < horizonCount && horizon[index]
                    let outsideLookAt = index < localCount && local[index]
                    target[index] = accepted
                        && horizonVisible
                        && outsideLookAt == false
                        && inputs[index].minCameraZoom <= cameraZoom
                    index += 1
                }
            }
        }}}}}
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
    /// arrive. Only the labels of `spans` are decided
    /// (`LabelActiveSpans`). Nil decides every label. Returns whether any
    /// label changed.
    @discardableResult
    static func localSuppression(inputs: [BaseLabelPresentationInput],
                                 pointInputs: [TilePointInput],
                                 anchors: [SIMD4<Float>],
                                 centerWorldMercator: SIMD2<Double>,
                                 reach: LocalDetailReach,
                                 spans: [Range<Int>]? = nil,
                                 into suppressed: inout [Bool]) -> Bool {
        let count = inputs.count
        if suppressed.count != count {
            suppressed = [Bool](repeating: false, count: count)
        }
        let spans = spans ?? [0..<count]
        let maximumDistance = reach.unitsPerMeter.map { $0 * max(0, reach.maximumDistanceMeters) }
        let eye = reach.eye
        var changed = false
        inputs.withUnsafeBufferPointer { inputs in
        pointInputs.withUnsafeBufferPointer { points in
        anchors.withUnsafeBufferPointer { anchors in
        suppressed.withUnsafeMutableBufferPointer { suppressed in
            let pointCount = points.count
            let anchorCount = anchors.count
            // The labels of a tile are a run: the tile's answer is found
            // once for the run.
            var lastTile = SIMD3<Int32>(-1, -1, -1)
            var lastTileOutside = false
            for span in spans {
                var index = span.lowerBound
                let end = min(span.upperBound, count)
                while index < end {
                    var outOfReach = false
                    if inputs[index].isLocal, index < pointCount {
                        let tile = points[index].tile
                        if tile != lastTile {
                            lastTile = tile
                            lastTileOutside = isWithinLookAtBlock(tile, mercator: centerWorldMercator) == false
                        }
                        outOfReach = lastTileOutside
                        if outOfReach == false, let maximumDistance, index < anchorCount {
                            let anchor = anchors[index]
                            let distance = simd_length(SIMD3<Float>(anchor.x, anchor.y, anchor.z) - eye)
                            outOfReach = distance > maximumDistance
                        }
                    }
                    if suppressed[index] != outOfReach {
                        suppressed[index] = outOfReach
                        changed = true
                    }
                    index += 1
                }
            }
        }}}}
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

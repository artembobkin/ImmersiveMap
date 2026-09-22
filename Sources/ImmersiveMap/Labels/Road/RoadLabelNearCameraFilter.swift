// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Decides whether a tile deserves road labels based on its VISIBLE screen area:
/// the tile quad is clipped in homogeneous coordinates against the near plane and
/// the viewport bounds, and metrics are computed from what is actually on screen.
/// So a near tile whose corners go behind the camera is judged fairly by its
/// huge visible part rather than by a degenerate projection of its corners.
enum RoadLabelNearCameraFilter {
    /// Minimum visible area: below the equivalent of a 150x150 point square the
    /// tile occupies too little of the screen for its road labels to be readable.
    /// The threshold is about readability, so it is in points: a denser display
    /// gives the same tile more pixels without giving the reader more to see.
    private static let minimumVisibleAreaPoints: Float = 150 * 150

    /// Minimum visible area PER TARGET-ZOOM TILE EQUIVALENT
    /// (visible area / 4^underzoom). A coarse parent of a distant strip may
    /// take half the screen, but the world inside it is compressed 4^N times
    /// and labels along its roads are degenerate. The normalization is
    /// zoom-agnostic and survives a change of the source maxzoom.
    private static let minimumVisibleAreaPerNativeTilePoints: Float = 100 * 100

    /// Minimum compression ratio of the visible polygon (area / long edge
    /// squared): a perspective-flattened ribbon is rejected regardless of
    /// area. Calibration: a top-down square is 1.0, a near tile at maximum
    /// tilt ~0.1-0.15, a ribbon at the horizon 0.02-0.05.
    private static let minimumProjectedCompressionRatio: Float = 0.07

    static func shouldKeepTile(clipCorners: [SIMD4<Float>],
                               viewportWidth: Float,
                               viewportHeight: Float,
                               screenScale: ScreenScale = .reference,
                               underzoomLevels: Int = 0) -> Bool {
        guard clipCorners.count == 4,
              viewportWidth.isFinite,
              viewportWidth > 0,
              viewportHeight.isFinite,
              viewportHeight > 0 else {
            return false
        }

        let visiblePolygon = clipToViewport(polygon: clipCorners)
        guard visiblePolygon.count >= 3 else {
            return false
        }

        let viewport = SIMD2<Float>(viewportWidth, viewportHeight)
        let screenPoints = visiblePolygon.map { vertex -> SIMD2<Float> in
            let ndc = SIMD2<Float>(vertex.x, vertex.y) / vertex.w
            return (ndc * 0.5 + 0.5) * viewport
        }

        let longestEdge = longestEdgeLength(points: screenPoints)
        guard longestEdge > .ulpOfOne else {
            return false
        }

        // The polygon is in device pixels, so an area threshold stated in points
        // squared scales by the square of the pixels-per-point.
        let pixelsPerPointSquared = screenScale.pixelsPerPoint * screenScale.pixelsPerPoint
        let visibleArea = polygonArea(points: screenPoints)
        let contentScale = Float(1 << (2 * min(max(underzoomLevels, 0), 10)))
        let compressionRatio = visibleArea / (longestEdge * longestEdge)
        return visibleArea >= minimumVisibleAreaPoints * pixelsPerPointSquared
            && visibleArea / contentScale >= minimumVisibleAreaPerNativeTilePoints * pixelsPerPointSquared
            && compressionRatio >= minimumProjectedCompressionRatio
    }

    static func makeTileCornerInputs(tile: VisibleTile) -> [TilePointInput] {
        let tileVector = SIMD3<Int32>(Int32(tile.x), Int32(tile.y), Int32(tile.z))
        return [
            TilePointInput(uv: SIMD2<Float>(0, 0), tile: tileVector, tileSlotIndex: 0),
            TilePointInput(uv: SIMD2<Float>(1, 0), tile: tileVector, tileSlotIndex: 0),
            TilePointInput(uv: SIMD2<Float>(1, 1), tile: tileVector, tileSlotIndex: 0),
            TilePointInput(uv: SIMD2<Float>(0, 1), tile: tileVector, tileSlotIndex: 0)
        ]
    }

    /// Sutherland-Hodgman in homogeneous coordinates: first the near plane
    /// (w > 0, points behind the camera are clipped before the perspective
    /// divide), then the four NDC viewport bounds.
    private static func clipToViewport(polygon: [SIMD4<Float>]) -> [SIMD4<Float>] {
        let planes: [(SIMD4<Float>) -> Float] = [
            { $0.w - 1e-4 },
            { $0.w + $0.x },
            { $0.w - $0.x },
            { $0.w + $0.y },
            { $0.w - $0.y }
        ]

        var clipped = polygon
        for plane in planes {
            guard clipped.count >= 3 else {
                return []
            }
            var next: [SIMD4<Float>] = []
            next.reserveCapacity(clipped.count + 1)
            for index in clipped.indices {
                let current = clipped[index]
                let following = clipped[(index + 1) % clipped.count]
                let currentDistance = plane(current)
                let followingDistance = plane(following)
                if currentDistance >= 0 {
                    next.append(current)
                }
                if (currentDistance >= 0) != (followingDistance >= 0) {
                    let t = currentDistance / (currentDistance - followingDistance)
                    next.append(current + (following - current) * t)
                }
            }
            clipped = next
        }
        return clipped
    }

    private static func polygonArea(points: [SIMD2<Float>]) -> Float {
        guard points.count >= 3 else {
            return 0
        }

        var doubledArea: Float = 0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            doubledArea += current.x * next.y - next.x * current.y
        }
        return abs(doubledArea) * 0.5
    }

    private static func longestEdgeLength(points: [SIMD2<Float>]) -> Float {
        var longestEdge: Float = 0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            longestEdge = max(longestEdge, simd_length(next - current))
        }
        return longestEdge
    }
}

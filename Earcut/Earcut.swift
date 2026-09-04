// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Part of the mapbox/earcut port; the ISC notice heads EarcutCore.swift and
// is repeated in THIRD-PARTY-NOTICES.md at the repository root.

/// Ear-clipping polygon triangulation: the whole public surface of the
/// `Earcut` module.
///
/// The input follows the reference implementation's flat layout so a caller
/// can hand over the coordinates it already has without building a ring
/// structure first:
///
/// - `data` holds every vertex of every ring back to back, `dim` numbers per
///   vertex (`x`, `y`, then any extra components, which are carried along and
///   ignored). The outer ring comes first, then the holes.
/// - `holeIndices` holds the vertex index (not the array offset) at which each
///   hole ring starts, in the order the holes appear in `data`.
///
/// Rings may be closed or open (a repeated first vertex is dropped), and
/// their winding does not matter: the outer ring is walked clockwise and the
/// holes counterclockwise regardless of how they arrive. The output is a flat
/// list of vertex indices into `data`, three per triangle, indexing vertices
/// (an index of `k` means the vertex at `data[k * dim]`).
///
/// ```swift
/// // A square with a smaller square cut out of its middle.
/// let data: [Double] = [
///     0, 0, 10, 0, 10, 10, 0, 10,   // outer ring, vertices 0-3
///     3, 3, 7, 3, 7, 7, 3, 7        // hole, vertices 4-7
/// ]
/// let triangles = Earcut.tessellate(data: data, holeIndices: [4])
/// // triangles.count == 24: eight triangles, each three vertex indices.
/// ```
///
/// Degenerate input (fewer than three vertices, a ring of zero area, a `dim`
/// below 2) yields an empty result rather than a trap. Self-intersecting
/// rings are handled the way the reference implementation handles them:
/// the algorithm cures small local intersections and splits what remains,
/// so the result is a best effort rather than a guaranteed cover.
public enum Earcut {
    /// Triangulates a polygon given as a flat coordinate array, with optional
    /// holes.
    ///
    /// - Parameters:
    ///   - data: Every ring's vertices back to back, `dim` numbers per vertex,
    ///     the outer ring first and then the holes.
    ///   - holeIndices: The vertex index at which each hole ring starts, in
    ///     the order the holes appear in `data`. Empty for a polygon with no
    ///     holes.
    ///   - dim: Numbers per vertex in `data`; the first two are `x` and `y`,
    ///     the rest are ignored. Must be at least 2.
    /// - Returns: Vertex indices into `data`, three per triangle. Empty when
    ///   the input has fewer than three vertices or no area.
    public static func tessellate(data: [Double], holeIndices: [Int] = [], dim: Int = 2) -> [UInt32] {
        guard dim >= 2, data.count >= dim * 3 else { return [] }
        let core = EarcutCore(data: data, dim: dim)
        return core.run(holeIndices: holeIndices)
    }

    /// Relative difference between the triangulated area and the polygon area
    /// (holes subtracted): the reference implementation's own measure of a
    /// triangulation's quality.
    ///
    /// Near zero means the triangles cover the polygon exactly. A caller that
    /// wants to check a result, or a test pinning the port, compares this
    /// against a small tolerance rather than inspecting the triangles.
    ///
    /// - Parameters:
    ///   - data: The coordinates handed to ``tessellate(data:holeIndices:dim:)``.
    ///   - holeIndices: The hole starts handed to it.
    ///   - dim: The numbers per vertex handed to it.
    ///   - triangles: The indices it returned.
    /// - Returns: `abs(triangleArea - polygonArea) / polygonArea`, or 0 when
    ///   both areas are zero.
    public static func deviation(data: [Double], holeIndices: [Int], dim: Int, triangles: [UInt32]) -> Double {
        let hasHoles = holeIndices.isEmpty == false
        let outerLen = hasHoles ? holeIndices[0] * dim : data.count

        var polygonArea = abs(signedArea(data: data, start: 0, end: outerLen, dim: dim))
        if hasHoles {
            for holeNumber in 0..<holeIndices.count {
                let start = holeIndices[holeNumber] * dim
                let end = holeNumber < holeIndices.count - 1 ? holeIndices[holeNumber + 1] * dim : data.count
                polygonArea -= abs(signedArea(data: data, start: start, end: end, dim: dim))
            }
        }

        var trianglesArea = 0.0
        for triangleStart in stride(from: 0, to: triangles.count, by: 3) {
            let a = Int(triangles[triangleStart]) * dim
            let b = Int(triangles[triangleStart + 1]) * dim
            let c = Int(triangles[triangleStart + 2]) * dim
            trianglesArea += abs(
                (data[a] - data[c]) * (data[b + 1] - data[a + 1]) -
                (data[a] - data[b]) * (data[c + 1] - data[a + 1]))
        }

        if polygonArea == 0 && trianglesArea == 0 {
            return 0
        }
        return abs((trianglesArea - polygonArea) / polygonArea)
    }

    static func signedArea(data: [Double], start: Int, end: Int, dim: Int) -> Double {
        var sum = 0.0
        var j = end - dim
        var i = start
        while i < end {
            sum += (data[j] - data[i]) * (data[i + 1] + data[j + 1])
            j = i
            i += dim
        }
        return sum
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Projection input for a single marker: an internal id (assigned by the
/// UI runtime, public Identifiable ids never cross this layer) and a cached
/// coordinate basis.
struct MarkerProjectionEntry: Equatable, Sendable {
    let id: UInt64
    let basis: GeoProjectionBasis
}

struct MarkerProjectionInput: Equatable, Sendable {
    static let empty = MarkerProjectionInput(entries: [])

    let entries: [MarkerProjectionEntry]
}

/// Source of marker coordinates for the frame engine. Read synchronously on
/// the main thread within a frame: the engine is single-threaded (display link
/// on the main runloop, see ImmersiveMapRenderDriver).
protocol MarkerRenderSource: AnyObject {
    var currentMarkerProjectionInput: MarkerProjectionInput { get }
}

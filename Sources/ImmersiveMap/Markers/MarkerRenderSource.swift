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

/// The `Markers` folder: only the value types and protocols that cross the
/// boundary between the SwiftUI marker overlays in `UI` and the frame that
/// projects them, the per-frame projection input and the projected screen
/// snapshot published back. Marker views, hosting and the projection math live
/// on their own sides of that boundary, and nothing of avatars, labels or
/// selection is here.
///
/// Source of marker coordinates for the frame engine. Read synchronously on
/// the main thread within a frame: the engine is single-threaded (display link
/// on the main runloop, see ImmersiveMapRenderDriver).
protocol MarkerRenderSource: AnyObject {
    var currentMarkerProjectionInput: MarkerProjectionInput { get }
}

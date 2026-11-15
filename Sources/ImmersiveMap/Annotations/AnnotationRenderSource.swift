// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// Projection input for a single annotation: an internal id (assigned by the
/// UI runtime, public Identifiable ids never cross this layer) and a cached
/// coordinate basis.
struct AnnotationProjectionEntry: Equatable, Sendable {
    let id: UInt64
    let basis: GeoProjectionBasis
}

struct AnnotationProjectionInput: Equatable, Sendable {
    static let empty = AnnotationProjectionInput(entries: [])

    let entries: [AnnotationProjectionEntry]
}

/// The `Annotations` folder: only the value types and protocols that cross the
/// boundary between the SwiftUI annotation overlays in `UI` and the frame that
/// projects them, the per-frame projection input and the projected screen
/// snapshot published back. Annotation views, hosting and the projection math live
/// on their own sides of that boundary, and nothing of pins, labels or
/// selection is here.
///
/// Source of annotation coordinates for the frame engine. Read synchronously on
/// the main thread within a frame: the engine is single-threaded (display link
/// on the main runloop, see ImmersiveMapRenderDriver).
protocol AnnotationRenderSource: AnyObject {
    var currentAnnotationProjectionInput: AnnotationProjectionInput { get }
}

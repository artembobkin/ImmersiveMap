// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// What the annotations' subsystem leaves for the engine to publish
/// (`FrameStateBoard`).
struct AnnotationFrameState: FrameState {
    static let empty = AnnotationFrameState(snapshot: nil)

    /// nil: no markers, nothing to publish. Empty snapshot: markers exist,
    /// but all are hidden, and the UI must hide the views.
    var snapshot: AnnotationProjectionSnapshot?
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Failures of an offline tour video export.
public enum ImmersiveMapVideoExportError: Error {
    /// The recorder is not attached to an `ImmersiveMapView` (attach it with
    /// the `tourVideoRecorder(_:)` modifier before exporting).
    case notAttached
    /// Another export driven by this recorder is still running.
    case exportAlreadyInProgress
    /// The export configuration failed validation; the message names the
    /// offending field.
    case invalidConfiguration(String)
    /// The tour has no shots.
    case emptyShots
    /// No Metal device is available for offscreen rendering.
    case metalUnavailable
    /// The engine's resources could not be loaded: its resource bundle was
    /// not found, or it holds no shader library. The message says which,
    /// and where it was searched.
    case resourcesUnavailable(String)
    /// The video writer failed; carries the underlying `AVAssetWriter` error
    /// when one was reported.
    case videoWriterFailure((any Error)?)
    /// The writer's pixel-buffer pool produced no buffer.
    case pixelBufferUnavailable
    /// The engine repeatedly failed to schedule an offscreen frame.
    case renderFrameFailure
    /// The export was cancelled; the partial file has been deleted.
    case cancelled
}

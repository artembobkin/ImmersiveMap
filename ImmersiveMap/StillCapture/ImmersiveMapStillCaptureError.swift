// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Why a still capture could not produce an image.
///
/// Deliberately separate from ``ImmersiveMapVideoExportError`` rather than
/// shared with it: half of that one's cases describe an encoder and a file on
/// disk, and neither exists here. A caller switching over this enum should not
/// have to reason about writer failures that cannot happen.
public enum ImmersiveMapStillCaptureError: Error, Equatable, Sendable {
    /// Another capture on this recorder has not finished yet.
    case captureAlreadyInProgress
    /// The configured geometry is out of range; the message names the field.
    case invalidConfiguration(String)
    /// No Metal device, or one that cannot back an offscreen render target.
    case metalUnavailable
    /// The renderer refused to schedule the frame, or the GPU reported failure.
    case renderFrameFailure
    /// The rendered pixels could not be turned into a `CGImage`.
    case imageCreationFailure
    /// The task was cancelled before the frame was captured.
    case cancelled
}

extension ImmersiveMapStillCaptureError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .captureAlreadyInProgress:
            return "A capture is already running on this recorder"
        case let .invalidConfiguration(field):
            return "Invalid still capture configuration: \(field)"
        case .metalUnavailable:
            return "Metal is unavailable on this device"
        case .renderFrameFailure:
            return "The map frame could not be rendered"
        case .imageCreationFailure:
            return "The rendered frame could not be converted into an image"
        case .cancelled:
            return "The still capture was cancelled"
        }
    }
}

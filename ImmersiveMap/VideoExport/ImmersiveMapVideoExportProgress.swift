// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Progress of an offline tour video export.
public struct ImmersiveMapVideoExportProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Building the offscreen engine and settling the first frame.
        case preparing
        /// Rendering and encoding tour frames.
        case rendering
        /// Finalizing the output file.
        case finishing
    }

    public let phase: Phase
    public let framesCompleted: Int
    public let totalFrames: Int

    public var fractionCompleted: Double {
        guard totalFrames > 0 else { return 0 }
        return min(1, Double(framesCompleted) / Double(totalFrames))
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// One frame the map drew on screen, delivered to
/// ``ImmersiveMapView/onFrameRendered(_:)`` right after the frame's commands
/// were handed to the GPU.
///
/// The moment is the CPU side of the frame: the render loop woke up, the
/// scene was updated, every pass was encoded and the command buffer was
/// committed. The GPU has not necessarily finished the frame and the pixels
/// are not necessarily on the display yet; the target timestamp says when
/// they are expected there. GPU time per pass is not part of the event, it
/// is read in Instruments from the `os_signpost` intervals the engine emits.
public struct ImmersiveMapRenderedFrame: Equatable, Sendable {
    /// The renderer's own frame counter, increasing by one per frame drawn
    /// since the map view was made. It restarts when the map is rebuilt for
    /// a settings change that recreates the renderer.
    public let frameIndex: UInt64
    /// Main-thread seconds the frame took from the render loop's wakeup to
    /// the commit of its command buffer.
    public let cpuDuration: TimeInterval
    /// When the frame is expected to appear on the display, on the
    /// `CACurrentMediaTime()` clock: the display link's target presentation
    /// timestamp for the update that drew it.
    public let targetPresentationTimestamp: TimeInterval

    public init(frameIndex: UInt64,
                cpuDuration: TimeInterval,
                targetPresentationTimestamp: TimeInterval) {
        self.frameIndex = frameIndex
        self.cpuDuration = cpuDuration
        self.targetPresentationTimestamp = targetPresentationTimestamp
    }
}

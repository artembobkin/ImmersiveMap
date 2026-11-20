// Copyright (c) 2025-2026 Artem Bobkin.
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
    /// Map tiles the frame wants to draw (`visibleTiles`). Zero before the
    /// first tile request, which is why `hasPendingWork == false` alone does
    /// not mean the map is drawn: check this too.
    public let visibleTileCount: Int
    /// Map tiles requested and not yet in (`requestedTiles`).
    public let pendingTileCount: Int
    /// Terrain tiles the frame wants that have not arrived. On the relief a
    /// tile is placed with its terrain or not at all, so the ground is empty
    /// where terrain waits.
    public let pendingTerrainTileCount: Int
    /// Scene models whose mesh has not finished loading.
    public let pendingSceneModelMeshCount: Int
    /// App layers whose mesh is not built yet.
    public let pendingLayerMeshCount: Int

    /// Whether anything the frame wants is still on its way: map tiles,
    /// terrain, scene model meshes or layer meshes. This is the still
    /// recorder's settle condition without its animation flags.
    public var hasPendingWork: Bool {
        pendingTileCount > 0 || pendingTerrainTileCount > 0
            || pendingSceneModelMeshCount > 0 || pendingLayerMeshCount > 0
    }

    public init(frameIndex: UInt64,
                cpuDuration: TimeInterval,
                targetPresentationTimestamp: TimeInterval,
                visibleTileCount: Int = 0,
                pendingTileCount: Int = 0,
                pendingTerrainTileCount: Int = 0,
                pendingSceneModelMeshCount: Int = 0,
                pendingLayerMeshCount: Int = 0) {
        self.frameIndex = frameIndex
        self.cpuDuration = cpuDuration
        self.targetPresentationTimestamp = targetPresentationTimestamp
        self.visibleTileCount = visibleTileCount
        self.pendingTileCount = pendingTileCount
        self.pendingTerrainTileCount = pendingTerrainTileCount
        self.pendingSceneModelMeshCount = pendingSceneModelMeshCount
        self.pendingLayerMeshCount = pendingLayerMeshCount
    }
}

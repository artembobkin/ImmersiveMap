// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The rasterized tiles' pictures of one renderer: the rasterizer that
/// renders them and the store that keeps them, shared by the plane's
/// ground and the sphere's. A picture is the same texture on both (north
/// at the top, the tile's square edge to edge), so the surface switch at
/// the end of the unroll finds its pictures already rendered. Main thread
/// only, like the frame engine.
final class TileRasterPictures {
    private let rasterizer: TileRasterizer
    private let store = TileRasterStore()

    init(rasterizer: TileRasterizer) {
        self.rasterizer = rasterizer
    }

    /// What a frame states about the pictures it asks for: everything of
    /// a picture's identity that is not the tile and its resolution.
    struct FrameRequest {
        let frameIndex: UInt64
        let pixelsPerPoint: Double
        let clearColor: MTLClearColor
        /// A picture bakes the building fills' footprint fade in at its
        /// own texel scale, so the panel's areas are part of what picture
        /// it is.
        let footprintGoneAreaPx: Float
        let footprintOpaqueAreaPx: Float

        init(frameContext: FrameContext, controls: DebugOverlayControlSnapshot) {
            let mapColor = frameContext.services.baseColors.map
            frameIndex = frameContext.frameIndex
            pixelsPerPoint = Double(frameContext.pixelsPerPoint)
            clearColor = MTLClearColor(red: Double(mapColor.x), green: Double(mapColor.y),
                                       blue: Double(mapColor.z), alpha: Double(mapColor.w))
            footprintGoneAreaPx = controls.buildingGoneAreaPixels
            footprintOpaqueAreaPx = controls.buildingOpaqueAreaPixels
        }
    }

    func key(tile: Tile, resolution: Int, groups: GroundLayerGroups, request: FrameRequest) -> TileRasterKey {
        TileRasterKey(tile: tile, resolution: resolution, groups: groups,
                      footprintGoneAreaPx: Int(request.footprintGoneAreaPx),
                      footprintOpaqueAreaPx: Int(request.footprintOpaqueAreaPx))
    }

    /// The tile's picture, rendered now when the store lacks it. Nil when
    /// the device declined it.
    func picture(of metalTile: MetalTile,
                 resolution: Int,
                 groups: GroundLayerGroups,
                 request: FrameRequest) -> MTLTexture? {
        let key = key(tile: metalTile.tile, resolution: resolution, groups: groups, request: request)
        if let texture = store.texture(for: key, frameIndex: request.frameIndex) {
            return texture
        }
        guard let texture = rasterizer.render(metalTile: metalTile,
                                              resolution: resolution,
                                              pixelsPerPoint: request.pixelsPerPoint,
                                              clearColor: request.clearColor,
                                              groups: groups,
                                              footprintGoneAreaPx: request.footprintGoneAreaPx,
                                              footprintOpaqueAreaPx: request.footprintOpaqueAreaPx) else {
            return nil
        }
        store.insert(texture, for: key, frameIndex: request.frameIndex)
        return texture
    }

    func releaseStale(frameIndex: UInt64) {
        store.releaseStale(frameIndex: frameIndex)
    }

    func removeAll() {
        store.removeAll()
        rasterizer.releaseScratch()
    }
}

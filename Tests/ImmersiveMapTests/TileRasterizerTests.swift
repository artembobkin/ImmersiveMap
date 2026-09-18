// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import simd
import XCTest

/// The rasterized tiles: the picture's camera, the zoom it stands for, and
/// the store that keeps the pictures for as long as frames ask for them.
final class TileRasterizerTests: XCTestCase {
    /// The projection maps the tile's world square onto the whole clip
    /// square, north (larger world y) at the top.
    func testTheProjectionMapsTheTileOntoTheClipSquare() {
        let projection = TileRasterizer.projection(tileOrigin: SIMD2<Float>(100, -300), tileSize: 50)
        func project(_ x: Float, _ y: Float) -> SIMD2<Float> {
            let clip = projection * SIMD4<Float>(x, y, 0, 1)
            XCTAssertEqual(clip.w, 1, "orthographic")
            return SIMD2<Float>(clip.x, clip.y)
        }
        XCTAssertEqual(project(100, -300), SIMD2<Float>(-1, -1), "the south-west corner")
        XCTAssertEqual(project(150, -250), SIMD2<Float>(1, 1), "the north-east corner")
        XCTAssertEqual(project(125, -275), SIMD2<Float>(0, 0), "the centre")
    }

    /// The flat render state of a picture makes one tile unit one world
    /// unit, so the drawer's model matrix scales by one.
    func testThePictureWorldHasOneUnitPerTileUnit() {
        let state = TileRasterizer.flatRenderState(tileZoom: 5)
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: 3, y: 7, z: 5, worldWrap: 0,
                                                                  flatRenderPan: state.pan,
                                                                  renderMapSize: state.renderMapSize)
        XCTAssertEqual(origin.z, 4096, accuracy: 1e-3)
    }

    /// A picture of 512 texels at one pixel per point is the map at the
    /// tile's own zoom, a 2048 one two levels in, and a Retina screen
    /// halves that.
    func testTheCameraZoomOfAPictureFollowsItsResolution() {
        XCTAssertEqual(TileRasterizer.cameraZoom(tileZoom: 14, resolution: 512, pixelsPerPoint: 1), 14, accuracy: 1e-9)
        XCTAssertEqual(TileRasterizer.cameraZoom(tileZoom: 14, resolution: 2048, pixelsPerPoint: 1), 16, accuracy: 1e-9)
        XCTAssertEqual(TileRasterizer.cameraZoom(tileZoom: 14, resolution: 2048, pixelsPerPoint: 2), 15, accuracy: 1e-9)
    }

    /// The store keeps a picture through `retentionFrames` frames after its
    /// last use and lets it go after.
    func testTheStoreReleasesPicturesNoFrameAsksFor() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let store = TileRasterStore()
        let key = TileRasterKey(tile: Tile(x: 1, y: 2, z: 3), resolution: 512)
        XCTAssertNil(store.texture(for: key, frameIndex: 1))
        store.insert(texture, for: key, frameIndex: 1)
        XCTAssertNotNil(store.texture(for: key, frameIndex: 10))
        store.releaseStale(frameIndex: 10 + TileRasterStore.retentionFrames)
        XCTAssertTrue(store.contains(key), "used at frame 10, kept to the edge of the retention")
        store.releaseStale(frameIndex: 11 + TileRasterStore.retentionFrames)
        XCTAssertFalse(store.contains(key))
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(store.contains(TileRasterKey(tile: Tile(x: 1, y: 2, z: 3), resolution: 1024)),
                       "A resolution is its own picture")
    }
}

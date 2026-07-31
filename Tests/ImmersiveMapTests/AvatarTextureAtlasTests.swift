// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import Metal
import XCTest

final class AvatarTextureAtlasTests: XCTestCase {
    private var device: MTLDevice!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal device unavailable")
    }

    /// Markers with the same image share one atlas slot.
    func testMarkersSharingImageShareOneSlot() throws {
        let atlas = AvatarTextureAtlas(device: device, atlasSize: 128, cellSize: 64, pagesMax: 1)
        let image = try Self.makeImage(gray: 0x80)
        atlas.beginFrame(1)

        let first = try XCTUnwrap(atlas.uploadImage(image))
        let second = try XCTUnwrap(atlas.slot(for: image))
        XCTAssertEqual(first.uvRect, second.uvRect)
        XCTAssertEqual(first.pageIndex, second.pageIndex)
        // Re-uploading the same image does not take a new slot.
        let reuploaded = try XCTUnwrap(atlas.uploadImage(image))
        XCTAssertEqual(reuploaded.uvRect, first.uvRect)
    }

    /// An overflowing atlas evicts the slot of an image not used in
    /// the current frame and doesn't touch the current frame's slots.
    func testLRUEvictionPrefersImagesUnusedThisFrame() throws {
        // 2x2 slots.
        let atlas = AvatarTextureAtlas(device: device, atlasSize: 128, cellSize: 64, pagesMax: 1)
        XCTAssertEqual(atlas.slotCapacity, 4)
        let images = try (0..<5).map { try Self.makeImage(gray: UInt8(0x10 * ($0 + 1))) }

        atlas.beginFrame(1)
        for index in 0..<4 {
            XCTAssertNotNil(atlas.uploadImage(images[index]), "image \(index)")
        }

        // Frame 2: images 1..3 are used, image 0 is untouched.
        atlas.beginFrame(2)
        for index in 1..<4 {
            XCTAssertNotNil(atlas.slot(for: images[index]))
        }
        // The fifth image evicts image zero (last used in frame 1).
        XCTAssertNotNil(atlas.uploadImage(images[4]))
        XCTAssertNil(atlas.slot(for: images[0]), "вытеснена")
        for index in 1..<5 {
            XCTAssertNotNil(atlas.slot(for: images[index]), "image \(index) на месте")
        }
    }

    /// An atlas fully occupied by the current frame's images does not evict them.
    func testFullAtlasOfCurrentFrameImagesRefusesUpload() throws {
        let atlas = AvatarTextureAtlas(device: device, atlasSize: 128, cellSize: 64, pagesMax: 1)
        let images = try (0..<5).map { try Self.makeImage(gray: UInt8(0x20 * ($0 + 1))) }

        atlas.beginFrame(1)
        for index in 0..<4 {
            XCTAssertNotNil(atlas.uploadImage(images[index]))
            _ = atlas.slot(for: images[index])
        }
        XCTAssertNil(atlas.uploadImage(images[4]),
                     "все слоты использованы в текущем кадре - вытеснять нечего")
        for index in 0..<4 {
            XCTAssertNotNil(atlas.slot(for: images[index]))
        }
    }

    private static func makeImage(gray: UInt8) throws -> CGImage {
        let side = 4
        let bytesPerRow = side * 4
        var data = Data(repeating: gray, count: bytesPerRow * side)
        let image = data.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(data: baseAddress,
                                          width: side,
                                          height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            return context.makeImage()
        }
        return try XCTUnwrap(image)
    }
}

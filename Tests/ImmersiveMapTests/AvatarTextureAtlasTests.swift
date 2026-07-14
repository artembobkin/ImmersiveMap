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

    /// Маркеры с одной и той же картинкой делят один слот атласа.
    func testMarkersSharingImageShareOneSlot() throws {
        let atlas = AvatarTextureAtlas(device: device, atlasSize: 128, cellSize: 64, pagesMax: 1)
        let image = try Self.makeImage(gray: 0x80)
        atlas.beginFrame(1)

        let first = try XCTUnwrap(atlas.uploadImage(image))
        let second = try XCTUnwrap(atlas.slot(for: image))
        XCTAssertEqual(first.uvRect, second.uvRect)
        XCTAssertEqual(first.pageIndex, second.pageIndex)
        // Повторная загрузка той же картинки не занимает новый слот.
        let reuploaded = try XCTUnwrap(atlas.uploadImage(image))
        XCTAssertEqual(reuploaded.uvRect, first.uvRect)
    }

    /// Переполненный атлас вытесняет слот картинки, не использованной в
    /// текущем кадре, и не трогает слоты текущего кадра.
    func testLRUEvictionPrefersImagesUnusedThisFrame() throws {
        // 2x2 слота.
        let atlas = AvatarTextureAtlas(device: device, atlasSize: 128, cellSize: 64, pagesMax: 1)
        XCTAssertEqual(atlas.slotCapacity, 4)
        let images = try (0..<5).map { try Self.makeImage(gray: UInt8(0x10 * ($0 + 1))) }

        atlas.beginFrame(1)
        for index in 0..<4 {
            XCTAssertNotNil(atlas.uploadImage(images[index]), "image \(index)")
        }

        // Кадр 2: используются картинки 1..3, картинка 0 не трогается.
        atlas.beginFrame(2)
        for index in 1..<4 {
            XCTAssertNotNil(atlas.slot(for: images[index]))
        }
        // Пятая картинка вытесняет нулевую (последнее использование - кадр 1).
        XCTAssertNotNil(atlas.uploadImage(images[4]))
        XCTAssertNil(atlas.slot(for: images[0]), "вытеснена")
        for index in 1..<5 {
            XCTAssertNotNil(atlas.slot(for: images[index]), "image \(index) на месте")
        }
    }

    /// Атлас, целиком занятый картинками текущего кадра, не вытесняет их.
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

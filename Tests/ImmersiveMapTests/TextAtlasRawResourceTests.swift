// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// The text atlases ship as raw BGRA8 pixels next to their JSON metrics:
/// the file is exactly the atlas the JSON describes, and the renderer
/// uploads it byte for byte.
final class TextAtlasRawResourceTests: XCTestCase {
    private let atlasNames = ["atlas", "atlas_thin"]

    func testEveryAtlasShipsItsPixelsRawAtTheSizeTheMetricsDescribe() throws {
        for name in atlasNames {
            let jsonURL = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"), "\(name).json ships")
            let pixelsURL = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "bgra"), "\(name).bgra ships")
            let atlas = try JSONDecoder().decode(AtlasData.self, from: Data(contentsOf: jsonURL)).atlas
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: pixelsURL.path)[.size] as? Int)
            XCTAssertEqual(size, atlas.width * atlas.height * 4,
                           "\(name).bgra holds one BGRA8 pixel per texel of the \(atlas.width)x\(atlas.height) atlas")
        }
    }

    func testTheRendererUploadsTheFileByteForByte() throws {
        let device = try MetalTestEnvironment.requireDevice(needsReadback: true)
        let library = try device.makeDefaultLibrary(bundle: .module)
        let renderer = TextRenderer(device: device, library: library)
        let pixelsURL = try XCTUnwrap(Bundle.module.url(forResource: "atlas", withExtension: "bgra"))
        let file = try Data(contentsOf: pixelsURL)

        let texture = try XCTUnwrap(renderer.texture)
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(texture.storageMode, .private, "The atlas keeps no CPU copy")
        XCTAssertEqual(file.count, texture.width * texture.height * 4)

        // The private texture is read back through a shared copy.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: texture.width,
                                                                  height: texture.height,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        let copy = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var readback = [UInt8](repeating: 0, count: file.count)
        copy.getBytes(&readback,
                      bytesPerRow: texture.width * 4,
                      from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                      mipmapLevel: 0)
        XCTAssertTrue(readback.elementsEqual(file), "What the GPU holds is the file")
    }
}

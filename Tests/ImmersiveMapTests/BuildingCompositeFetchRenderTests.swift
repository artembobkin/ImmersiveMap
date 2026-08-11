// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// Exercises the framebuffer-fetch building composite against a real GPU pass
/// shaped like the world pass (drawable color, memoryless building attachment,
/// depth): the fullscreen composite must blend the building attachment over
/// the map with the shared alpha and reset the depth back to the far plane.
/// Requires the compiled Metal library and an Apple-family GPU, so it skips
/// under `swift test` and on Intel Macs, and runs in the xcodebuild suite.
final class BuildingCompositeFetchRenderTests: XCTestCase {
    func testCompositeFetchBlendsBuildingAttachmentAndResetsDepth() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard let library = try? device.makeDefaultLibrary(bundle: .module) else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
        guard device.supportsFamily(.apple1) else {
            throw XCTSkip("Framebuffer fetch requires an Apple-family GPU")
        }
        guard device.hasUnifiedMemory else {
            throw XCTSkip("Unified-memory GPU is required for direct texture readback")
        }

        let size = 16
        let pipeline = ExtrudedTilePipeline(metalDevice: device,
                                            pixelFormat: .bgra8Unorm,
                                            library: library,
                                            sampleCount: 1,
                                            supportsFramebufferFetch: true)

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                       width: size,
                                                                       height: size,
                                                                       mipmapped: false)
        colorDescriptor.usage = [.renderTarget]
        colorDescriptor.storageMode = .shared
        let colorTexture = try XCTUnwrap(device.makeTexture(descriptor: colorDescriptor))

        // The building attachment lives and dies inside the pass, exactly like
        // production: memoryless, cleared in, dontCare out.
        let buildingDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                          width: size,
                                                                          height: size,
                                                                          mipmapped: false)
        buildingDescriptor.usage = [.renderTarget]
        buildingDescriptor.storageMode = .memoryless
        let buildingTexture = try XCTUnwrap(device.makeTexture(descriptor: buildingDescriptor))

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                       width: size,
                                                                       height: size,
                                                                       mipmapped: false)
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        let depthTexture = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))

        // Mirrors SharedRenderResources: the composite passes every fragment
        // and writes depth; the restored state passes and writes nothing.
        let resetDescriptor = MTLDepthStencilDescriptor()
        resetDescriptor.depthCompareFunction = .always
        resetDescriptor.isDepthWriteEnabled = true
        let compositeDepthResetState = try XCTUnwrap(device.makeDepthStencilState(descriptor: resetDescriptor))
        let disabledDescriptor = MTLDepthStencilDescriptor()
        disabledDescriptor.depthCompareFunction = .always
        disabledDescriptor.isDepthWriteEnabled = false
        let depthDisabledState = try XCTUnwrap(device.makeDepthStencilState(descriptor: disabledDescriptor))

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = colorTexture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        // The map underneath the composite: opaque blue.
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1)
        passDescriptor.colorAttachments[1].texture = buildingTexture
        passDescriptor.colorAttachments[1].loadAction = .clear
        passDescriptor.colorAttachments[1].storeAction = .dontCare
        // Stands in for rendered buildings: opaque red across the frame
        // (premultiplied, full coverage).
        passDescriptor.colorAttachments[1].clearColor = MTLClearColorMake(1, 0, 0, 1)
        passDescriptor.depthAttachment.texture = depthTexture
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.storeAction = .store
        // Stands in for the depth the buildings wrote; the composite must
        // erase it back to the far plane.
        passDescriptor.depthAttachment.clearDepth = 0.25

        let commandQueue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor))
        BuildingExtrusionDrawer.drawCompositeFetch(renderEncoder: encoder,
                                                   alpha: 0.5,
                                                   extrudedTilePipeline: pipeline,
                                                   compositeDepthResetState: compositeDepthResetState,
                                                   depthDisabledState: depthDisabledState)
        encoder.endEncoding()

        // Depth is not directly readable: copy it into a buffer within the
        // same command buffer.
        let depthBuffer = try XCTUnwrap(device.makeBuffer(length: size * size * MemoryLayout<Float>.stride,
                                                          options: .storageModeShared))
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: depthTexture,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size, height: size, depth: 1),
                  to: depthBuffer,
                  destinationOffset: 0,
                  destinationBytesPerRow: size * MemoryLayout<Float>.stride,
                  destinationBytesPerImage: size * size * MemoryLayout<Float>.stride)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)

        // Premultiplied over at alpha 0.5: half the building red plus half the
        // map blue on every pixel.
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { buffer in
            colorTexture.getBytes(buffer.baseAddress!,
                                  bytesPerRow: size * 4,
                                  from: MTLRegionMake2D(0, 0, size, size),
                                  mipmapLevel: 0)
        }
        for corner in [0, (size - 1) * 4, (size * size - 1) * 4] {
            XCTAssertEqual(Double(pixels[corner]) / 255.0, 0.5, accuracy: 0.01, "blue")
            XCTAssertEqual(Double(pixels[corner + 1]) / 255.0, 0.0, accuracy: 0.01, "green")
            XCTAssertEqual(Double(pixels[corner + 2]) / 255.0, 0.5, accuracy: 0.01, "red")
            XCTAssertEqual(Double(pixels[corner + 3]) / 255.0, 1.0, accuracy: 0.01, "alpha")
        }

        let depths = depthBuffer.contents().bindMemory(to: Float.self, capacity: size * size)
        for index in [0, size - 1, size * size - 1] {
            XCTAssertEqual(depths[index], 1.0,
                           "The composite must reset depth to the far plane so later "
                           + "world layers keep ignoring composited building depth")
        }
    }
}

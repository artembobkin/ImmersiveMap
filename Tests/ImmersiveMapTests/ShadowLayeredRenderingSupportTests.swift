// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// The cascade shadow maps rasterize through layered rendering, which the iOS
/// Simulator does not support: a pass descriptor asking for more than one
/// slice fails Metal validation there, and that aborts the process instead of
/// returning an error. These pin that the shared resources can be built
/// wherever the tests run, which is what the crash-on-launch regression broke.
final class ShadowLayeredRenderingSupportTests: XCTestCase {
    private func makeDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        return device
    }

    func testSupportMatchesTheEnvironment() throws {
        let device = try makeDevice()
        let isSupported = ShadowCascadeAtlas.supportsLayeredRendering(device: device)
        #if targetEnvironment(simulator)
        XCTAssertFalse(isSupported,
                       "The simulator has no layered rendering, whatever its GPU family reports")
        #else
        XCTAssertEqual(isSupported,
                       device.supportsFamily(.apple5) || device.supportsFamily(.mac2),
                       "On real hardware the answer is the GPU family")
        #endif
    }

    private func makeFallbackTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = ShadowCascadeAtlas.depthPixelFormat
        descriptor.width = 1
        descriptor.height = 1
        descriptor.arrayLength = ShadowCascadeAtlas.cascadeCount
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    /// The regression itself, asserted on the descriptors rather than on a
    /// crash: the clear used to ask for every slice at once unconditionally,
    /// and where layered rendering is missing that aborts the process at
    /// launch. Metal's validation layer is what turns it into an abort, and
    /// it does not reach a simulator test process, so the property is checked
    /// directly instead.
    @MainActor
    func testTheFallbackClearNeverAsksForSlicesItCannotWrite() throws {
        let device = try makeDevice()
        let texture = try makeFallbackTexture(device: device)

        let layered = SharedRenderResources.makeShadowFallbackClearDescriptors(texture: texture,
                                                                               supportsLayeredRendering: true)
        XCTAssertEqual(layered.count, 1, "One pass clears every slice where layered rendering exists")
        XCTAssertEqual(layered.first?.renderTargetArrayLength, ShadowCascadeAtlas.cascadeCount)

        let perSlice = SharedRenderResources.makeShadowFallbackClearDescriptors(texture: texture,
                                                                                supportsLayeredRendering: false)
        XCTAssertEqual(perSlice.count, ShadowCascadeAtlas.cascadeCount,
                       "Without layered rendering each slice needs its own pass")
        XCTAssertEqual(perSlice.map(\.depthAttachment.slice), Array(0..<ShadowCascadeAtlas.cascadeCount),
                       "Every slice must be cleared, since receivers sample the texture while shadows are off")
        for passDescriptor in perSlice {
            XCTAssertEqual(passDescriptor.renderTargetArrayLength, 0,
                           "Asking for more than one slice is what fails validation and aborts the process")
            XCTAssertEqual(passDescriptor.depthAttachment.loadAction, .clear)
            XCTAssertEqual(passDescriptor.depthAttachment.clearDepth, 1.0)
        }
    }

    /// Building the shared resources is what crashed at launch, so it is done
    /// here too: on the simulator this is the path that used to abort.
    @MainActor
    func testSharedResourcesBuildWhereverTheTestsRun() throws {
        let device = try makeDevice()
        guard (try? device.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }

        let fallback = SharedRenderResources.shared().shadowFallbackTexture

        XCTAssertEqual(fallback.textureType, .type2DArray)
        XCTAssertEqual(fallback.arrayLength, ShadowCascadeAtlas.cascadeCount)
        XCTAssertEqual(fallback.pixelFormat, ShadowCascadeAtlas.depthPixelFormat)
    }
}

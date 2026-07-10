// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Metal

final class FrameAttachmentStore {
    private let metalDevice: MTLDevice
    private let renderSampleCount: Int
    // MSAA color и все depth-атачменты живут только внутри своего render pass
    // (load .clear, store .dontCare/.multisampleResolve), поэтому на Apple TBDR GPU
    // им не нужна память вне tile memory.
    private let transientStorageMode: MTLStorageMode
    private var colorTexture: MTLTexture?
    private var postProcessingInputTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    private var overlayDepthTexture: MTLTexture?
    private var buildingWinnerIDTexture: MTLTexture?
    private var buildingWinnerDepthTexture: MTLTexture?

    init(metalDevice: MTLDevice,
         renderSampleCount: Int) {
        self.metalDevice = metalDevice
        self.renderSampleCount = max(1, renderSampleCount)
        // Симулятор по документации Metal требует .private для depth/MSAA-атачментов,
        // даже если фактически memoryless там работает.
        #if targetEnvironment(simulator)
        self.transientStorageMode = .private
        #else
        self.transientStorageMode = metalDevice.supportsFamily(.apple1) ? .memoryless : .private
        #endif
    }

    var currentBuildingWinnerIDTexture: MTLTexture? {
        buildingWinnerIDTexture
    }

    var currentPostProcessingInputTexture: MTLTexture? {
        postProcessingInputTexture
    }

    var sampleCount: Int {
        renderSampleCount
    }

    func ensureColorTexture(drawSize: CGSize,
                            pixelFormat: MTLPixelFormat) -> MTLTexture? {
        guard renderSampleCount > 1 else { return nil }

        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        if let colorTexture,
           colorTexture.width == width,
           colorTexture.height == height,
           colorTexture.pixelFormat == pixelFormat,
           colorTexture.sampleCount == renderSampleCount {
            return colorTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.textureType = .type2DMultisample
        descriptor.sampleCount = renderSampleCount
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = transientStorageMode
        let newTexture = metalDevice.makeTexture(descriptor: descriptor)
        newTexture?.label = RenderResourceName.colorTexture.rawValue
        colorTexture = newTexture
        return newTexture
    }

    func ensurePostProcessingInputTexture(drawSize: CGSize,
                                          pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        if let postProcessingInputTexture,
           postProcessingInputTexture.width == width,
           postProcessingInputTexture.height == height,
           postProcessingInputTexture.pixelFormat == pixelFormat {
            return postProcessingInputTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let newTexture = metalDevice.makeTexture(descriptor: descriptor)
        newTexture?.label = RenderResourceName.postProcessingInputTexture.rawValue
        postProcessingInputTexture = newTexture
        return newTexture
    }

    func ensureDepthTexture(drawSize: CGSize) -> MTLTexture? {
        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        if let depthTexture,
           depthTexture.width == width,
           depthTexture.height == height,
           depthTexture.sampleCount == renderSampleCount {
            return depthTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        if renderSampleCount > 1 {
            descriptor.textureType = .type2DMultisample
            descriptor.sampleCount = renderSampleCount
        }
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = transientStorageMode
        let newTexture = metalDevice.makeTexture(descriptor: descriptor)
        newTexture?.label = RenderResourceName.depthTexture.rawValue
        depthTexture = newTexture
        return newTexture
    }

    func ensureOverlayDepthTexture(drawSize: CGSize) -> MTLTexture? {
        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        if let overlayDepthTexture,
           overlayDepthTexture.width == width,
           overlayDepthTexture.height == height {
            return overlayDepthTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = transientStorageMode
        let newTexture = metalDevice.makeTexture(descriptor: descriptor)
        newTexture?.label = RenderResourceName.overlayDepthTexture.rawValue
        overlayDepthTexture = newTexture
        return newTexture
    }

    func ensureBuildingWinnerIDTexture(drawSize: CGSize) -> MTLTexture? {
        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        if let buildingWinnerIDTexture,
           buildingWinnerIDTexture.width == width,
           buildingWinnerIDTexture.height == height {
            return buildingWinnerIDTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let newTexture = metalDevice.makeTexture(descriptor: descriptor)
        newTexture?.label = RenderResourceName.buildingWinnerIDTexture.rawValue
        buildingWinnerIDTexture = newTexture
        return newTexture
    }

    func ensureBuildingWinnerDepthTexture(drawSize: CGSize) -> MTLTexture? {
        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        if let buildingWinnerDepthTexture,
           buildingWinnerDepthTexture.width == width,
           buildingWinnerDepthTexture.height == height {
            return buildingWinnerDepthTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = transientStorageMode
        let newTexture = metalDevice.makeTexture(descriptor: descriptor)
        newTexture?.label = RenderResourceName.buildingWinnerDepthTexture.rawValue
        buildingWinnerDepthTexture = newTexture
        return newTexture
    }

    func reset() {
        colorTexture = nil
        postProcessingInputTexture = nil
        depthTexture = nil
        overlayDepthTexture = nil
        buildingWinnerIDTexture = nil
        buildingWinnerDepthTexture = nil
    }
}

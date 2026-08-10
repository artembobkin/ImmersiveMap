// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Metal

final class FrameAttachmentStore {
    private let metalDevice: MTLDevice
    private let renderSampleCount: Int
    // MSAA color and all depth attachments live only within their render pass
    // (load .clear, store .dontCare/.multisampleResolve), so on Apple TBDR GPUs
    // they need no memory outside tile memory.
    private let transientStorageMode: MTLStorageMode
    private var colorTexture: MTLTexture?
    private var postProcessingInputTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    private var overlayDepthTexture: MTLTexture?
    private var buildingImageColorTexture: MTLTexture?
    private var buildingImageTexture: MTLTexture?
    private var shadowMapTexture: MTLTexture?

    init(metalDevice: MTLDevice,
         renderSampleCount: Int) {
        self.metalDevice = metalDevice
        self.renderSampleCount = max(1, renderSampleCount)
        // Memoryless keeps these pass-transient attachments entirely in tile
        // memory on Apple-family GPUs; Intel Macs fail the family check and the
        // simulator lacks support, both fall back to .private. Verified on
        // Apple Silicon macOS with the offscreen pixel-comparison suites (an
        // older comment claimed an empty render there; it no longer reproduces).
        #if targetEnvironment(simulator)
        self.transientStorageMode = .private
        #else
        self.transientStorageMode = metalDevice.supportsFamily(.apple1) ? .memoryless : .private
        #endif
    }

    var currentBuildingImageTexture: MTLTexture? {
        buildingImageTexture
    }

    var currentShadowMapTexture: MTLTexture? {
        shadowMapTexture
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

    /// MSAA target of the offscreen building image pass: lives only within the pass
    /// (clear → multisampleResolve), so it uses transient storage.
    func ensureBuildingImageColorTexture(drawSize: CGSize,
                                         pixelFormat: MTLPixelFormat) -> MTLTexture? {
        guard renderSampleCount > 1 else { return nil }

        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        if let buildingImageColorTexture,
           buildingImageColorTexture.width == width,
           buildingImageColorTexture.height == height,
           buildingImageColorTexture.pixelFormat == pixelFormat {
            return buildingImageColorTexture
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
        newTexture?.label = RenderResourceName.buildingImageColorTexture.rawValue
        buildingImageColorTexture = newTexture
        return newTexture
    }

    /// Readable buildings image: the resolve texture of the MSAA pass (or the direct
    /// target without MSAA). The world pass composites it over the map with a shared alpha.
    func ensureBuildingImageTexture(drawSize: CGSize,
                                    pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        if let buildingImageTexture,
           buildingImageTexture.width == width,
           buildingImageTexture.height == height,
           buildingImageTexture.pixelFormat == pixelFormat {
            return buildingImageTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let newTexture = metalDevice.makeTexture(descriptor: descriptor)
        newTexture?.label = RenderResourceName.buildingImageTexture.rawValue
        buildingImageTexture = newTexture
        return newTexture
    }

    /// Depth of the directional-light pass, an N:1 cascade atlas
    /// (near → far, left to right) sampled later by the world and
    /// buildingImage passes: unlike the transient depth attachments it must
    /// survive its pass (`.store`) and be readable, so it is always `.private`
    /// with `.shaderRead`, never memoryless.
    func ensureShadowMapTexture(resolution: Int) -> MTLTexture? {
        guard resolution > 0 else { return nil }

        let width = resolution * ShadowCascadeAtlas.cascadeCount
        if let shadowMapTexture,
           shadowMapTexture.width == width,
           shadowMapTexture.height == resolution {
            return shadowMapTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                  width: width,
                                                                  height: resolution,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let newTexture = metalDevice.makeTexture(descriptor: descriptor)
        newTexture?.label = RenderResourceName.shadowMapTexture.rawValue
        shadowMapTexture = newTexture
        return newTexture
    }

    func reset() {
        colorTexture = nil
        postProcessingInputTexture = nil
        depthTexture = nil
        overlayDepthTexture = nil
        buildingImageColorTexture = nil
        buildingImageTexture = nil
        shadowMapTexture = nil
    }
}

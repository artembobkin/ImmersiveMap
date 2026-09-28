// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Metal

final class FrameAttachmentStore {
    private let metalDevice: MTLDevice
    private let renderSampleCount: Int
    // MSAA color and the depth attachments live only within their render pass
    // (load .clear, store .dontCare/.multisampleResolve), so on Apple TBDR GPUs
    // they need no memory outside tile memory. The one exception is the world
    // depth on a frame whose road names the buildings paint over: with one
    // sample it is stored for the label pass to read (`keptForLabels`).
    private let transientStorageMode: MTLStorageMode
    private var colorTexture: MTLTexture?
    private var postProcessingInputTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    /// The multisampled world depth resolved to one sample for the label
    /// pass to read, on frames that keep it.
    private var sceneDepthResolveTexture: MTLTexture?
    private var overlayDepthTexture: MTLTexture?
    private var shadowMapTexture: MTLTexture?
    private var groundShadowMaskTexture: MTLTexture?

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

    var currentShadowMapTexture: MTLTexture? {
        shadowMapTexture
    }

    var currentGroundShadowMaskTexture: MTLTexture? {
        groundShadowMaskTexture
    }

    var currentPostProcessingInputTexture: MTLTexture? {
        postProcessingInputTexture
    }

    var sampleCount: Int {
        renderSampleCount
    }

    /// Whether the world depth can be kept for the label pass: always with
    /// one sample, and with several where the GPU resolves depth.
    var supportsSceneDepth: Bool {
        renderSampleCount == 1
            || metalDevice.supportsFamily(.apple3)
            || metalDevice.supportsFamily(.mac2)
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

    /// The world pass's depth. `keptForLabels` on a single-sampled frame
    /// makes it a stored, shader-readable texture the label pass reads
    /// (`sceneDepthTexture`); otherwise it lives in tile memory alone. A
    /// multisampled depth stays transient either way and is resolved into
    /// `ensureSceneDepthResolveTexture` instead.
    func ensureDepthTexture(drawSize: CGSize, keptForLabels: Bool = false) -> MTLTexture? {
        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        let isReadable = keptForLabels && renderSampleCount == 1
        let storageMode = isReadable ? MTLStorageMode.private : transientStorageMode
        if let depthTexture,
           depthTexture.width == width,
           depthTexture.height == height,
           depthTexture.sampleCount == renderSampleCount,
           depthTexture.storageMode == storageMode,
           depthTexture.usage.contains(.shaderRead) == isReadable {
            return depthTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        if renderSampleCount > 1 {
            descriptor.textureType = .type2DMultisample
            descriptor.sampleCount = renderSampleCount
        }
        descriptor.usage = isReadable ? [.renderTarget, .shaderRead] : [.renderTarget]
        descriptor.storageMode = storageMode
        let newTexture = metalDevice.makeTexture(descriptor: descriptor)
        newTexture?.label = RenderResourceName.depthTexture.rawValue
        depthTexture = newTexture
        return newTexture
    }

    /// One sample of the multisampled world depth, resolved at the end of
    /// the world pass for the label pass to read.
    func ensureSceneDepthResolveTexture(drawSize: CGSize) -> MTLTexture? {
        let width = Int(drawSize.width)
        let height = Int(drawSize.height)
        guard width > 0, height > 0 else { return nil }

        if let sceneDepthResolveTexture,
           sceneDepthResolveTexture.width == width,
           sceneDepthResolveTexture.height == height {
            return sceneDepthResolveTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let newTexture = metalDevice.makeTexture(descriptor: descriptor)
        newTexture?.label = "SceneDepthResolveTexture"
        sceneDepthResolveTexture = newTexture
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

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8,
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

    /// Depth of the directional-light pass, a texture array with one square
    /// slice per cascade (near → far), sampled later by the world pass:
    /// unlike the transient depth attachments it must
    /// survive its pass (`.store`) and be readable, so it is always `.private`
    /// with `.shaderRead`, never memoryless.
    func ensureShadowMapTexture(resolution: Int) -> MTLTexture? {
        guard resolution > 0 else { return nil }

        if let shadowMapTexture,
           shadowMapTexture.width == resolution,
           shadowMapTexture.height == resolution {
            return shadowMapTexture
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = ShadowCascadeAtlas.depthPixelFormat
        descriptor.width = resolution
        descriptor.height = resolution
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let newTexture = metalDevice.makeTexture(descriptor: descriptor)
        newTexture?.label = RenderResourceName.shadowMapTexture.rawValue
        shadowMapTexture = newTexture
        return newTexture
    }

    /// The ground shadow mask: one 8-bit factor per mask pixel (half the
    /// drawable's resolution, see `GroundShadowMaskPipeline.resolutionScale`),
    /// written by the mask pass and sampled by the flat ground layers of the
    /// world pass. Single-sample and readable, so `.private` (never
    /// memoryless).
    func ensureGroundShadowMaskTexture(drawSize: CGSize) -> MTLTexture? {
        let maskSize = GroundShadowMaskPipeline.maskSize(for: drawSize)
        let width = Int(maskSize.width)
        let height = Int(maskSize.height)
        guard width > 0, height > 0 else { return nil }

        if let groundShadowMaskTexture,
           groundShadowMaskTexture.width == width,
           groundShadowMaskTexture.height == height {
            return groundShadowMaskTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GroundShadowMaskPipeline.pixelFormat,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let newTexture = metalDevice.makeTexture(descriptor: descriptor)
        newTexture?.label = RenderResourceName.groundShadowMaskTexture.rawValue
        groundShadowMaskTexture = newTexture
        return newTexture
    }

    func reset() {
        colorTexture = nil
        postProcessingInputTexture = nil
        depthTexture = nil
        overlayDepthTexture = nil
        shadowMapTexture = nil
        groundShadowMaskTexture = nil
    }
}

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
    private var buildingImageColorTexture: MTLTexture?
    private var buildingImageTexture: MTLTexture?

    init(metalDevice: MTLDevice,
         renderSampleCount: Int) {
        self.metalDevice = metalDevice
        self.renderSampleCount = max(1, renderSampleCount)
        // Memoryless - это оптимизация tile memory для iOS TBDR GPU. Симулятор её не
        // поддерживает; на нативном macOS (в т.ч. Apple Silicon) memoryless-аттачменты
        // для этого пайплайна дают пустой рендер, поэтому там используем .private.
        #if targetEnvironment(simulator) || os(macOS)
        self.transientStorageMode = .private
        #else
        self.transientStorageMode = metalDevice.supportsFamily(.apple1) ? .memoryless : .private
        #endif
    }

    var currentBuildingImageTexture: MTLTexture? {
        buildingImageTexture
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

    /// MSAA-таргет offscreen-пасса building image: живёт только внутри пасса
    /// (clear → multisampleResolve), поэтому использует transient storage.
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

    /// Читаемое изображение зданий: resolve-текстура MSAA-пасса (или прямой
    /// таргет без MSAA). Его world-пасс накладывает на карту с общей альфой.
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

    func reset() {
        colorTexture = nil
        postProcessingInputTexture = nil
        depthTexture = nil
        overlayDepthTexture = nil
        buildingImageColorTexture = nil
        buildingImageTexture = nil
    }
}

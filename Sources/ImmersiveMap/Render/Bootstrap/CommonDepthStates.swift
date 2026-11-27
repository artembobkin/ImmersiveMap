// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// The depth states that belong to no feature: plain depth tests with no
/// stencil, which several features draw by. A state that carries a
/// feature's stencil lives with that feature (`TilePriorityDepthStates`,
/// `SceneModelSharedResources`), built on the descriptors here.
struct CommonDepthStates: SharedGPUResources {
    /// The depth neither tested nor written: the overlay passes, and what
    /// every subsystem leaves the encoder with.
    let disabled: MTLDepthStencilState
    /// The scene depth, lessEqual and written: the standing geometry (the
    /// buildings, the models, the shadow casters), and the label passes. The
    /// labels rasterize at the far plane and their fragments write one of
    /// two depths just short of it (TextShader.metal), fill nearer than
    /// halo, so a later glyph's halo never covers an earlier glyph's fill.
    let scene: MTLDepthStencilState
    /// The scene depth tested, lessEqual, and never written: the sky
    /// layers (the space background and the stars), drawn first on the
    /// sphere at the far plane against the cleared depth, the tile
    /// geometry blending over them, and the globe's caps.
    let sceneReadOnly: MTLDepthStencilState
    /// The flat ground: tested against the depth the opaque buildings wrote
    /// before it (strictly closer wins, so a wall base never loses to the
    /// ground plane it stands on), never written, since every ground layer
    /// is blended and lies on the same plane. Under a solid building the
    /// ground fails the test before its fragment is shaded.
    let ground: MTLDepthStencilState

    static func make(_ build: SharedGPUResourceBuild) -> CommonDepthStates {
        let device = build.device
        return CommonDepthStates(disabled: device.makeDepthStencilState(descriptor: disabledDescriptor())!,
                                 scene: device.makeDepthStencilState(descriptor: sceneDescriptor())!,
                                 sceneReadOnly: device.makeDepthStencilState(descriptor: sceneReadOnlyDescriptor())!,
                                 ground: device.makeDepthStencilState(descriptor: groundDescriptor())!)
    }

    // MARK: - Descriptors

    static func disabledDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }

    static func sceneDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true
        return descriptor
    }

    static func sceneReadOnlyDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }

    static func groundDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .less
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }
}

/// A 1x1 depth texture cleared to the far plane, for a slot a shader
/// references statically on a frame whose real texture was not made: the
/// binding is mandatory even where a uniform skips the read. Depth textures
/// cannot be filled from the CPU, so a no-draw pass clears each slice once,
/// when the texture is made.
enum FallbackDepthTexture {
    /// `arrayLength` nil makes a plain `depth2d`, a number a
    /// `depth2d_array` of that many slices.
    static func make(device: MTLDevice,
                     pixelFormat: MTLPixelFormat,
                     arrayLength: Int?,
                     label: String) -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = arrayLength == nil ? .type2D : .type2DArray
        descriptor.arrayLength = arrayLength ?? 1
        descriptor.pixelFormat = pixelFormat
        descriptor.width = 1
        descriptor.height = 1
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        texture.label = label

        // A throwaway queue: the clears run once per process, before any
        // view samples the texture. One plain pass per slice, never a
        // layered pass, which the iOS Simulator does not implement.
        guard let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer() else {
            return texture
        }
        for slice in 0..<(arrayLength ?? 1) {
            let passDescriptor = clearDescriptor(texture: texture, slice: slice)
            commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)?.endEncoding()
        }
        commandBuffer.commit()
        return texture
    }

    /// The no-draw pass that leaves one slice of a fallback texture
    /// cleared to the far plane. Every receiver samples the texture while
    /// its real one is off, so it has to arrive cleared.
    static func clearDescriptor(texture: MTLTexture, slice: Int = 0) -> MTLRenderPassDescriptor {
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.depthAttachment.texture = texture
        passDescriptor.depthAttachment.slice = slice
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.storeAction = .store
        passDescriptor.depthAttachment.clearDepth = 1.0
        return passDescriptor
    }
}

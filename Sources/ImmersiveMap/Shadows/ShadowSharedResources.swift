// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// What the shadows' receivers share: the pipeline of the ground shadow
/// mask (`GroundShadowMaskRenderSubsystem`) and the textures bound in the
/// shadows' slots on a frame without them.
struct ShadowSharedResources: SharedGPUResources {
    let groundMaskPipeline: GroundShadowMaskPipeline
    /// Bound at the shadow-map slot when the shadow pass is skipped: receiver
    /// shaders reference the texture statically and Metal validation requires a
    /// bound depth texture even though strength = 0 skips the sampling branch.
    /// One texel per cascade slice, cleared to 1.0 ("lit everywhere")
    /// (`FallbackDepthTexture`).
    let shadowFallbackTexture: MTLTexture
    /// Bound at the ground shadow mask slot of the flat ground pipeline when
    /// the mask pass did not run this frame: the shader guards the read with
    /// the disabled uniform's zero strength, but the binding itself is
    /// mandatory. A 1x1 "lit" texel, filled from the CPU.
    let groundMaskFallbackTexture: MTLTexture

    static func make(_ build: SharedGPUResourceBuild) -> ShadowSharedResources {
        ShadowSharedResources(
            groundMaskPipeline: GroundShadowMaskPipeline(metalDevice: build.device, library: build.library),
            shadowFallbackTexture: FallbackDepthTexture.make(device: build.device,
                                                             pixelFormat: ShadowCascadeAtlas.depthPixelFormat,
                                                             arrayLength: ShadowCascadeAtlas.sliceCount,
                                                             label: "ShadowFallbackTexture"),
            groundMaskFallbackTexture: makeGroundMaskFallbackTexture(device: build.device))
    }

    /// One lit texel for the ground pipeline's mask slot on frames without
    /// the mask pass. A color texture, so it can be filled from the CPU.
    private static func makeGroundMaskFallbackTexture(device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GroundShadowMaskPipeline.pixelFormat,
                                                                  width: 1,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        #if os(macOS)
        descriptor.storageMode = .managed
        #else
        descriptor.storageMode = .shared
        #endif
        let texture = device.makeTexture(descriptor: descriptor)!
        texture.label = "GroundShadowMaskFallbackTexture"
        var lit: UInt8 = 255
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &lit, bytesPerRow: 1)
        return texture
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The fog on the ground of the flat map (`ImmersiveMapSettings
/// .GroundFogSettings`) as the shaders read it (GroundFog.h). The feature
/// owns the fog's settings and its math. It draws nothing of its own:
/// every subsystem that draws something standing on the map binds this
/// uniform at `bufferIndex` and its shader mixes its colour toward the
/// fog's (`applyGroundFog`). The globe has no fog: there and with the fog
/// off the uniform's strength is zero and the shaders leave every colour.
struct GroundFogUniform {
    /// Mirror of `kGroundFogBufferIndex` in GroundFog.h.
    static let bufferIndex = 12

    var colorAndDensity: SIMD4<Float>
    var eyeAndInverseDistance: SIMD4<Float>
    /// The height, the start distance, the most it veils, the strength.
    var parameters: SIMD4<Float>

    static let disabled = GroundFogUniform(colorAndDensity: .zero,
                                           eyeAndInverseDistance: SIMD4<Float>(0, 0, 1, 1),
                                           parameters: SIMD4<Float>(1, 0, 0, 0))

    /// The fog a frame draws with. The camera looks at the render world's
    /// origin on the plane, so the eye's distance from it is the camera
    /// distance every length is stated in.
    /// Only the plane is fogged: the sphere's shaders bind nothing of it,
    /// and the plane draws once the globe has unrolled into it, so the fog
    /// is there at full strength from the plane's first frame.
    static func resolve(settings: ImmersiveMapSettings,
                        renderSurfaceMode: ViewMode,
                        cameraEye: SIMD3<Float>) -> GroundFogUniform {
        let fog = settings.scene.groundFog
        let cameraDistance = simd_length(cameraEye)
        guard fog.isEnabled,
              renderSurfaceMode == .flat,
              cameraDistance > 0,
              cameraDistance.isFinite else {
            return .disabled
        }
        let color = fog.color ?? settings.scene.fog.horizonColor
        return GroundFogUniform(colorAndDensity: SIMD4<Float>(color, max(fog.density, 0)),
                                eyeAndInverseDistance: SIMD4<Float>(cameraEye, 1 / cameraDistance),
                                parameters: SIMD4<Float>(max(fog.height, 1e-4),
                                                         max(fog.startDistance, 0),
                                                         min(max(fog.maximumOpacity, 0), 1),
                                                         1))
    }

    static func resolve(frameContext: FrameContext) -> GroundFogUniform {
        resolve(settings: frameContext.services.settings,
                renderSurfaceMode: frameContext.renderSurfaceMode,
                cameraEye: frameContext.cameraEye)
    }

    /// Binds the fog for every fogged fragment shader the encoder draws
    /// with next.
    static func bind(_ uniform: GroundFogUniform, encoder: MTLRenderCommandEncoder) {
        var value = uniform
        encoder.setFragmentBytes(&value, length: MemoryLayout<GroundFogUniform>.stride, index: bufferIndex)
    }
}

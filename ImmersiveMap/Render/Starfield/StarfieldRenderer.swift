// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//  Task Notes
//  - Purpose: render the globe-aligned starfield when globe view is active.
//  - Stars: fixed buffer of unit-sphere positions, rotated by globe pan, drawn with a separate projection
//    to avoid affecting map depth precision. Tuned via ImmersiveMapSettings.scene.starfield.
//  - Space itself is the world pass's clear color (ImmersiveMapSettings.scene.space), not a draw.

import MetalKit
import simd

final class StarfieldRenderer {
    private struct StarVertex {
        let position: SIMD3<Float>
        let size: Float
        let brightness: Float
        let temperature: Float
        let twinklePhase: Float
        let halo: Float
    }

    private struct StarfieldParams {
        let rotation: matrix_float4x4
        let radiusScale: Float
        let padding: SIMD3<Float>
    }

    private let pipeline: StarfieldPipeline
    /// Nil when the model is empty (`starCount == 0`) or the buffer allocation failed:
    /// the star pass is then skipped, space (the pass clear color) still shows.
    private let verticesBuffer: MTLBuffer?
    private let verticesCount: Int
    private let config: ImmersiveMapSettings.StarfieldSettings
    private var cachedAspect: Float?
    private var cachedProjection: matrix_float4x4?

    init(metalDevice: MTLDevice,
         pipeline: StarfieldPipeline,
         config: ImmersiveMapSettings.StarfieldSettings) {
        self.pipeline = pipeline
        self.config = config

        let stars = StarfieldModel.makeStars(config: config)
        let buffer = Self.makeVerticesBuffer(metalDevice: metalDevice, stars: stars)
        verticesBuffer = buffer
        verticesCount = buffer == nil ? 0 : stars.count
    }

    /// Packs the model into a vertex buffer, or returns nil when there is nothing to draw.
    ///
    /// `makeBuffer(bytes:length:)` returns nil for a zero length, so an empty starfield
    /// must not reach the allocation at all. Returning nil lets the caller skip the star
    /// pass instead of force unwrapping and crashing.
    ///
    /// Internal rather than private so the empty case is covered by a behavioral test.
    static func makeVerticesBuffer(metalDevice: MTLDevice,
                                   stars: [StarfieldModel.Star]) -> MTLBuffer? {
        guard !stars.isEmpty else { return nil }

        let vertices = stars.map { star in
            StarVertex(position: star.position,
                       size: star.size,
                       brightness: star.brightness,
                       temperature: star.temperature,
                       twinklePhase: star.twinklePhase,
                       halo: star.halo)
        }
        return metalDevice.makeBuffer(bytes: vertices,
                                      length: MemoryLayout<StarVertex>.stride * vertices.count)
    }

    func draw(renderEncoder: MTLRenderCommandEncoder,
              globe: GlobeUniform,
              cameraView: matrix_float4x4,
              cameraEye: SIMD3<Float>,
              drawSize: CGSize,
              nowTime: Float) {
        guard let verticesBuffer, verticesCount > 0 else {
            return
        }
        let aspect = Float(drawSize.width) / Float(drawSize.height)
        if cachedAspect != aspect || cachedProjection == nil {
            cachedProjection = Matrix.perspectiveMatrix(fovRadians: Float.pi / 4,
                                                        aspect: aspect,
                                                        near: config.near,
                                                        far: config.far)
            cachedAspect = aspect
        }
        guard let starProjection = cachedProjection else {
            return
        }
        let starCameraMatrix = starProjection * cameraView
        var starCameraUniform = CameraUniform(matrix: starCameraMatrix,
                                              eye: cameraEye,
                                              padding: 0)
        // The pan rotation, once per frame on the CPU, in the row-vector
        // layout the shader multiplies with (the exact matrix the tile
        // stages use, see GlobeFrameConstantsUniform).
        let rotation = GlobeFrameConstantsUniform.rotationMatrix(
            panLatitude: globe.panY * Float(ImmersiveMapProjection.maxMercatorLatitude),
            panLongitude: globe.panX * Float.pi
        )
        var globeData = globe
        var params = StarfieldParams(rotation: rotation,
                                     radiusScale: config.radiusScale,
                                     padding: SIMD3<Float>(repeating: 0))
        var time = nowTime

        pipeline.selectStarsPipeline(renderEncoder: renderEncoder)
        renderEncoder.setVertexBuffer(verticesBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBytes(&starCameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&globeData, length: MemoryLayout<GlobeUniform>.stride, index: 2)
        renderEncoder.setVertexBytes(&params, length: MemoryLayout<StarfieldParams>.stride, index: 3)
        renderEncoder.setFragmentBytes(&time, length: MemoryLayout<Float>.stride, index: 0)
        renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: verticesCount)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//  Task Notes
//  - Purpose: render sky background, globe-aligned starfield, and Sun glow when globe view is active.
//  - Stars: fixed buffer of unit-sphere positions, rotated by globe pan, drawn with a separate projection
//    to avoid affecting map depth precision. Tuned via ImmersiveMapSettings.scene.starfield.
//  - Space: background clear color configured in ImmersiveMapSettings.scene.space.
//  - Sun: fullscreen glow pass drawn after stars so later globe layers can occlude it.

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
        let radiusScale: Float
        let padding: SIMD3<Float>
    }

    private struct BackgroundParams {
        let deepColor: SIMD4<Float>
        let hazeColor: SIMD4<Float>
        let nebulaColorA: SIMD4<Float>
        let nebulaColorB: SIMD4<Float>
        let transitionTargetColor: SIMD4<Float>
        let controls: SIMD4<Float>
    }

    private struct BackgroundViewParams {
        let aspect: Float
        let tanHalfFov: Float
        let padding: SIMD2<Float>
    }

    private let pipeline: StarfieldPipeline
    private let verticesBuffer: MTLBuffer
    private let verticesCount: Int
    private let config: ImmersiveMapSettings.StarfieldSettings
    private let backgroundParams: BackgroundParams
    private var cachedAspect: Float?
    private var cachedProjection: matrix_float4x4?

    init(metalDevice: MTLDevice,
         layer: CAMetalLayer,
         library: MTLLibrary,
         sampleCount: Int = 1,
         spaceColor: SIMD4<Double>,
         transitionTargetColor: SIMD4<Double>,
         config: ImmersiveMapSettings.StarfieldSettings) {
        pipeline = StarfieldPipeline(metalDevice: metalDevice,
                                     layer: layer,
                                     library: library,
                                     sampleCount: sampleCount)
        self.config = config
        backgroundParams = Self.makeBackgroundParams(spaceColor: spaceColor,
                                                     transitionTargetColor: transitionTargetColor)

        let stars = StarfieldModel.makeStars(config: config).map { star in
            StarVertex(position: star.position,
                       size: star.size,
                       brightness: star.brightness,
                       temperature: star.temperature,
                       twinklePhase: star.twinklePhase,
                       halo: star.halo)
        }
        verticesCount = stars.count
        verticesBuffer = metalDevice.makeBuffer(bytes: stars,
                                                length: MemoryLayout<StarVertex>.stride * stars.count)!
    }

    func draw(renderEncoder: MTLRenderCommandEncoder,
              globe: GlobeUniform,
              earthScene: EarthSceneUniform,
              cameraView: matrix_float4x4,
              cameraEye: SIMD3<Float>,
              drawSize: CGSize,
              nowTime: Float) {
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
        var backgroundViewParams = BackgroundViewParams(aspect: aspect,
                                                        tanHalfFov: tan(Float.pi / 8.0),
                                                        padding: SIMD2<Float>(repeating: 0))
        var globeData = globe
        var params = StarfieldParams(radiusScale: config.radiusScale, padding: SIMD3<Float>(repeating: 0))
        var backgroundParams = backgroundParams
        var time = nowTime

        pipeline.selectBackgroundPipeline(renderEncoder: renderEncoder)
        renderEncoder.setFragmentBytes(&backgroundParams,
                                       length: MemoryLayout<BackgroundParams>.stride,
                                       index: 0)
        renderEncoder.setFragmentBytes(&backgroundViewParams,
                                       length: MemoryLayout<BackgroundViewParams>.stride,
                                       index: 1)
        renderEncoder.setFragmentBytes(&globeData,
                                       length: MemoryLayout<GlobeUniform>.stride,
                                       index: 2)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        pipeline.selectStarsPipeline(renderEncoder: renderEncoder)
        renderEncoder.setVertexBuffer(verticesBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBytes(&starCameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&globeData, length: MemoryLayout<GlobeUniform>.stride, index: 2)
        renderEncoder.setVertexBytes(&params, length: MemoryLayout<StarfieldParams>.stride, index: 3)
        renderEncoder.setFragmentBytes(&time, length: MemoryLayout<Float>.stride, index: 0)
        renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: verticesCount)

        var sunState = EarthSceneSunVisualState.make(earthScene: earthScene,
                                                     globe: globe,
                                                     cameraMatrix: starCameraMatrix,
                                                     cameraEye: cameraEye,
                                                     drawSize: drawSize,
                                                     starfieldRadiusScale: config.radiusScale)
        guard sunState.hasVisibleContribution(earthScene: earthScene) else {
            return
        }

        var earthSceneData = earthScene
        pipeline.selectSunPipeline(renderEncoder: renderEncoder)
        renderEncoder.setFragmentBytes(&earthSceneData,
                                       length: MemoryLayout<EarthSceneUniform>.stride,
                                       index: 0)
        renderEncoder.setFragmentBytes(&sunState,
                                       length: MemoryLayout<EarthSceneSunVisualState>.stride,
                                       index: 1)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private static func makeBackgroundParams(spaceColor: SIMD4<Double>,
                                             transitionTargetColor: SIMD4<Double>) -> BackgroundParams {
        let base = SIMD3<Float>(Float(spaceColor.x), Float(spaceColor.y), Float(spaceColor.z))
        let deep = simd_clamp(base * SIMD3<Float>(0.55, 0.58, 0.82) + SIMD3<Float>(0.002, 0.004, 0.018),
                              SIMD3<Float>(repeating: 0.0),
                              SIMD3<Float>(repeating: 1.0))
        let haze = simd_clamp(base * SIMD3<Float>(1.5, 1.45, 1.7) + SIMD3<Float>(0.015, 0.028, 0.075),
                              SIMD3<Float>(repeating: 0.0),
                              SIMD3<Float>(repeating: 1.0))
        let nebulaA = SIMD3<Float>(0.10, 0.19, 0.42)
        let nebulaB = SIMD3<Float>(0.05, 0.32, 0.48)

        return BackgroundParams(
            deepColor: SIMD4<Float>(deep, 1.0),
            hazeColor: SIMD4<Float>(haze, 1.0),
            nebulaColorA: SIMD4<Float>(nebulaA, 1.0),
            nebulaColorB: SIMD4<Float>(nebulaB, 1.0),
            transitionTargetColor: SIMD4<Float>(Float(transitionTargetColor.x),
                                                Float(transitionTargetColor.y),
                                                Float(transitionTargetColor.z),
                                                Float(transitionTargetColor.w)),
            controls: SIMD4<Float>(0.33, 2.15, 0.22, 0.0)
        )
    }
}

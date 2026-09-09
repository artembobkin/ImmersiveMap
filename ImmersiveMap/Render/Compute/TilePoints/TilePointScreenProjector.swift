// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TilePointScreenProjector.swift
//  ImmersiveMap
//

import simd

struct TilePointScreenProjector {
    func project(snapshot: TilePointToScreenPointSnapshot,
                 frameContext: FrameContext,
                 tileOriginData: [FlatTileOriginData]) -> [ScreenPointOutput] {
        guard snapshot.pointsCount > 0 else {
            return []
        }

        switch frameContext.screenSpaceProjectionMode {
        case .flat:
            // In flat mode the horizon mask is identical to the visible flag:
            // neither the horizonVisibility array nor a masking copy is needed.
            return projectFlatScreenPoints(snapshot: snapshot,
                                           frameContext: frameContext,
                                           tileOriginData: tileOriginData)
        case .globe:
            return screenPointsWithHorizonMask(projectGlobe(snapshot: snapshot,
                                                            frameContext: frameContext))
        }
    }

    func projectWithHorizonVisibility(snapshot: TilePointToScreenPointSnapshot,
                                      frameContext: FrameContext,
                                      tileOriginData: [FlatTileOriginData]) -> TilePointScreenProjectionResult {
        var result = TilePointScreenProjectionResult.empty
        projectWithHorizonVisibility(snapshot: snapshot,
                                     frameContext: frameContext,
                                     tileOriginData: tileOriginData,
                                     screenPoints: &result.screenPoints,
                                     horizonVisibility: &result.horizonVisibility)
        return result
    }

    /// The same projection written into the caller's arrays, which are
    /// resized to the snapshot only when they do not fit: a frame with a
    /// stable label set projects without allocating.
    func projectWithHorizonVisibility(snapshot: TilePointToScreenPointSnapshot,
                                      frameContext: FrameContext,
                                      tileOriginData: [FlatTileOriginData],
                                      screenPoints: inout [ScreenPointOutput],
                                      horizonVisibility: inout [Bool]) {
        let count = snapshot.pointsCount
        if screenPoints.count != count {
            screenPoints = Array(repeating: ScreenPointOutput(position: .zero, depth: 0, visible: 0), count: count)
        }
        if horizonVisibility.count != count {
            horizonVisibility = Array(repeating: false, count: count)
        }
        guard count > 0 else {
            return
        }

        switch frameContext.screenSpaceProjectionMode {
        case .flat:
            projectFlatScreenPoints(snapshot: snapshot,
                                    frameContext: frameContext,
                                    tileOriginData: tileOriginData,
                                    into: &screenPoints)
            for index in 0..<count {
                horizonVisibility[index] = screenPoints[index].visible != 0
            }
        case .globe:
            projectGlobe(snapshot: snapshot,
                         frameContext: frameContext,
                         screenPoints: &screenPoints,
                         horizonVisibility: &horizonVisibility)
        }
    }

    /// Clip-space coordinates of flat-projection points, without perspective divide
    /// or discarding points behind the camera: the consumer (the road label filter)
    /// clips the polygon against the near plane and viewport itself to measure the
    /// visible screen area. Invalid slots yield w = -1 (culled by the clip).
    func projectFlatClipSpacePoints(snapshot: TilePointToScreenPointSnapshot,
                                    frameContext: FrameContext,
                                    tileOriginData: [FlatTileOriginData]) -> [SIMD4<Float>] {
        let cameraMatrix = frameContext.cameraMatrices.projectionView
        var outputs = Array(repeating: SIMD4<Float>(0, 0, 0, -1),
                            count: snapshot.pointsCount)

        for index in snapshot.pointInputs.indices {
            let input = snapshot.pointInputs[index]
            let tileSlotIndex = Int(input.tileSlotIndex)
            guard tileSlotIndex >= 0,
                  tileSlotIndex < snapshot.tileSlotVisibleTileIndices.count else {
                continue
            }

            let visibleTileIndex = Int(snapshot.tileSlotVisibleTileIndices[tileSlotIndex])
            guard visibleTileIndex >= 0,
                  visibleTileIndex < tileOriginData.count else {
                continue
            }

            let originData = tileOriginData[visibleTileIndex]
            // v grows from the NORTH edge, the flat render world is y-up:
            // the same 1 - v as the GPU kernel (TilePointToScreen.metal).
            let local = SIMD2<Float>(input.uv.x * originData.size,
                                     (1.0 - input.uv.y) * originData.size)
            let worldPosition = originData.panRelativeOrigin + local
            let world = SIMD4<Float>(worldPosition.x, worldPosition.y, 0.0, 1.0)
            outputs[index] = cameraMatrix * world
        }

        return outputs
    }

    private func projectFlatScreenPoints(snapshot: TilePointToScreenPointSnapshot,
                                         frameContext: FrameContext,
                                         tileOriginData: [FlatTileOriginData]) -> [ScreenPointOutput] {
        var outputs = Array(repeating: ScreenPointOutput(position: .zero, depth: 0, visible: 0),
                            count: snapshot.pointsCount)
        projectFlatScreenPoints(snapshot: snapshot,
                                frameContext: frameContext,
                                tileOriginData: tileOriginData,
                                into: &outputs)
        return outputs
    }

    private func projectFlatScreenPoints(snapshot: TilePointToScreenPointSnapshot,
                                         frameContext: FrameContext,
                                         tileOriginData: [FlatTileOriginData],
                                         into outputs: inout [ScreenPointOutput]) {
        let viewport = SIMD2<Float>(Float(frameContext.drawSize.width), Float(frameContext.drawSize.height))
        let cameraMatrix = frameContext.cameraMatrices.projectionView
        let invisible = ScreenPointOutput(position: .zero, depth: 0, visible: 0)

        for index in snapshot.pointInputs.indices {
            let input = snapshot.pointInputs[index]
            let tileSlotIndex = Int(input.tileSlotIndex)
            guard tileSlotIndex >= 0,
                  tileSlotIndex < snapshot.tileSlotVisibleTileIndices.count else {
                outputs[index] = invisible
                continue
            }

            let visibleTileIndex = Int(snapshot.tileSlotVisibleTileIndices[tileSlotIndex])
            guard visibleTileIndex >= 0,
                  visibleTileIndex < tileOriginData.count else {
                outputs[index] = invisible
                continue
            }

            let originData = tileOriginData[visibleTileIndex]
            // v grows from the NORTH edge, the flat render world is y-up:
            // the same 1 - v as the GPU kernel (TilePointToScreen.metal).
            let local = SIMD2<Float>(input.uv.x * originData.size,
                                     (1.0 - input.uv.y) * originData.size)
            let worldPosition = originData.panRelativeOrigin + local
            let world = SIMD4<Float>(worldPosition.x, worldPosition.y, 0.0, 1.0)
            let clip = cameraMatrix * world
            outputs[index] = screenPointFromClip(clip: clip, viewportSize: viewport)
        }
    }

    private func projectGlobe(snapshot: TilePointToScreenPointSnapshot,
                              frameContext: FrameContext) -> TilePointScreenProjectionResult {
        var result = TilePointScreenProjectionResult(
            screenPoints: Array(repeating: ScreenPointOutput(position: .zero, depth: 0, visible: 0), count: snapshot.pointsCount),
            horizonVisibility: Array(repeating: false, count: snapshot.pointsCount))
        projectGlobe(snapshot: snapshot,
                     frameContext: frameContext,
                     screenPoints: &result.screenPoints,
                     horizonVisibility: &result.horizonVisibility)
        return result
    }

    private func projectGlobe(snapshot: TilePointToScreenPointSnapshot,
                              frameContext: FrameContext,
                              screenPoints outputs: inout [ScreenPointOutput],
                              horizonVisibility: inout [Bool]) {
        let viewport = SIMD2<Float>(Float(frameContext.drawSize.width), Float(frameContext.drawSize.height))
        let cameraUniform = frameContext.cameraUniform
        let globe = frameContext.globeRenderUniform
        let constants = GlobeProjectionConstants(globe: globe)

        for index in snapshot.pointInputs.indices {
            let input = snapshot.pointInputs[index]
            let projection = globeProjectTileUV(input: input,
                                                cameraUniform: cameraUniform,
                                                constants: constants)
            var output = screenPointFromClip(clip: projection.clip, viewportSize: viewport)
            var horizonVisible = false
            if output.visible != 0 {
                horizonVisible = globeProjectionPassesHorizon(worldPosition: projection.worldPosition,
                                                              cameraUniform: cameraUniform,
                                                              constants: constants)
                output.visibilityAlpha = 1.0
            }
            outputs[index] = output
            horizonVisibility[index] = horizonVisible
        }
    }

    private func screenPointsWithHorizonMask(_ result: TilePointScreenProjectionResult) -> [ScreenPointOutput] {
        var screenPoints = result.screenPoints
        let count = min(screenPoints.count, result.horizonVisibility.count)
        for index in 0..<count where !result.horizonVisibility[index] {
            screenPoints[index].visible = 0
            screenPoints[index].visibilityAlpha = 0.0
        }
        return screenPoints
    }

    private func screenPointFromClip(clip: SIMD4<Float>,
                                     viewportSize: SIMD2<Float>) -> ScreenPointOutput {
        guard clip.w > 0.0 else {
            return ScreenPointOutput(position: .zero, depth: 0.0, visible: 0, visibilityAlpha: 0.0)
        }

        let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
        let depth = clip.z / clip.w
        let position = (ndc * 0.5 + 0.5) * viewportSize
        return ScreenPointOutput(position: position, depth: depth, visible: 1, visibilityAlpha: 1.0)
    }

    private func globeProjectTileUV(input: TilePointInput,
                                    cameraUniform: CameraUniform,
                                    constants: GlobeProjectionConstants) -> GlobeProjectionResult {
        let zPow = powf(2.0, Float(input.tile.z))
        let size = 1.0 / zPow
        let vertexUvX = input.uv.x / zPow + size * Float(input.tile.x)
        let mercatorV = (Float(input.tile.y) + input.uv.y) / zPow
        let latitudeAtUv = atan(sinh(Float.pi * (1.0 - 2.0 * mercatorV)))
        let longitudeAtUv = vertexUvX * (2.0 * Float.pi) - Float.pi
        return globeProjectLatLon(latitude: latitudeAtUv,
                                  longitude: longitudeAtUv,
                                  cameraUniform: cameraUniform,
                                  constants: constants)
    }

    private func globeProjectLatLon(latitude: Float,
                                    longitude: Float,
                                    cameraUniform: CameraUniform,
                                    constants: GlobeProjectionConstants) -> GlobeProjectionResult {
        let sphereWorldPosition = constants.rotatedSphereWorldPosition(latitude: latitude,
                                                                       longitude: longitude)
        let flatWorldPosition = constants.flatWorldPosition(latitude: latitude,
                                                            longitude: longitude)
        let transition = constants.globe.transition
        let worldPosition = sphereWorldPosition + (flatWorldPosition - sphereWorldPosition) * transition
        let clip = cameraUniform.matrix * SIMD4<Float>(worldPosition, 1.0)
        return GlobeProjectionResult(clip: clip, worldPosition: worldPosition)
    }

    private func globeProjectionPassesHorizon(worldPosition: SIMD3<Float>,
                                             cameraUniform: CameraUniform,
                                             constants: GlobeProjectionConstants) -> Bool {
        let globeCenter = SIMD3<Float>(0.0, 0.0, -constants.globe.radius)
        let toCamera = cameraUniform.eye - globeCenter
        if simd_length(toCamera) <= 0.0 || constants.globe.transition >= 0.95 {
            return true
        }

        let dotToCamera = simd_dot(worldPosition - globeCenter, toCamera)
        return dotToCamera >= constants.horizonThreshold
    }
}

private struct GlobeProjectionResult {
    let clip: SIMD4<Float>
    let worldPosition: SIMD3<Float>
}

private struct GlobeProjectionConstants {
    let globe: GlobeUniform
    let panLatitude: Float
    let panLongitude: Float
    let mapSize: Float
    let panMercatorY: Float
    let rotationMatrix: matrix_float4x4
    let horizonThreshold: Float

    init(globe: GlobeUniform) {
        self.globe = globe
        let maxLatitude = Float(ImmersiveMapProjection.maxMercatorLatitude)
        self.panLatitude = globe.panY * maxLatitude
        self.panLongitude = globe.panX * .pi
        let distortion = cos(panLatitude)
        let mapSizeScale = (1.0 - globe.transition) * distortion + globe.transition
        self.mapSize = 2.0 * .pi * globe.radius * mapSizeScale
        self.panMercatorY = Float(ImmersiveMapProjection.yMercatorNormalized(latitude: Double(panLatitude)))
        self.rotationMatrix = GlobeProjectionConstants.makeRotationMatrix(panLatitude: panLatitude,
                                                                          panLongitude: panLongitude)
        let horizonFade = GlobeProjectionConstants.smoothstep(edge0: 0.8, edge1: 0.95, x: globe.transition)
        self.horizonThreshold = (1.0 - horizonFade) * (globe.radius * globe.radius) + horizonFade * -1e6
    }

    func rotatedSphereWorldPosition(latitude: Float,
                                    longitude: Float) -> SIMD3<Float> {
        let phi = latitude - (.pi * 0.5)
        let theta = longitude + .pi

        let x = globe.radius * sin(phi) * sin(theta)
        let y = globe.radius * cos(phi)
        let z = globe.radius * sin(phi) * cos(theta)
        let rotatedPosition = simd_transpose(rotationMatrix) * SIMD4<Float>(x, y, z, 1.0)
        return SIMD3<Float>(rotatedPosition.x,
                            rotatedPosition.y,
                            rotatedPosition.z - globe.radius)
    }

    func flatWorldPosition(latitude: Float,
                           longitude: Float) -> SIMD3<Float> {
        let normalizedWorldX = (longitude + .pi) / (2.0 * .pi)
        let mercatorY = Float(ImmersiveMapProjection.yMercatorNormalized(latitude: Double(latitude)))
        let halfMapSize = mapSize * 0.5
        let flatX = Float(ImmersiveMapProjection.wrap(value: Double(normalizedWorldX * mapSize - halfMapSize + globe.panX * halfMapSize),
                                             size: Double(mapSize)))
        let flatY = (mercatorY - panMercatorY) * halfMapSize
        return SIMD3<Float>(flatX, flatY, 0.0)
    }

    private static func makeRotationMatrix(panLatitude: Float,
                                           panLongitude: Float) -> matrix_float4x4 {
        let cx = cos(-panLatitude)
        let sx = sin(-panLatitude)
        let cy = cos(-panLongitude)
        let sy = sin(-panLongitude)

        return matrix_float4x4(columns: (
            SIMD4<Float>(cy, 0, -sy, 0),
            SIMD4<Float>(sy * sx, cx, cy * sx, 0),
            SIMD4<Float>(sy * cx, -sx, cy * cx, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = simd_clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)
    }
}

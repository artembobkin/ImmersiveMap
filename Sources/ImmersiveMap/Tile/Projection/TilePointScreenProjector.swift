// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  TilePointScreenProjector.swift
//  ImmersiveMap
//

import simd

struct TilePointScreenProjector {
    /// Whether a flat point rises by the ground relief under it
    /// (`GroundReliefFrame`), as the labels do. The debug overlay projects
    /// on the plane instead: its tile frames and watermarks are read, not
    /// looked at, and a watermark's letters lifted one by one by a slope
    /// come out torn.
    var liftsByRelief = true

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
        var perspectiveScales: [Float] = []
        var anchorPositions: [SIMD4<Float>] = []
        projectWithHorizonVisibility(snapshot: snapshot,
                                     frameContext: frameContext,
                                     tileOriginData: tileOriginData,
                                     screenPoints: &result.screenPoints,
                                     horizonVisibility: &result.horizonVisibility,
                                     perspectiveScales: &perspectiveScales,
                                     anchorPositions: &anchorPositions)
        return result
    }

    /// The same projection written into the caller's arrays, which are
    /// resized to the snapshot only when they do not fit: a frame with a
    /// stable label set projects without allocating. On the flat map a
    /// point with a roof (`TilePointInput.roofHeight`) is lifted onto it.
    ///
    /// `perspectiveScales` receives each point's shrink for its distance:
    /// the camera's depth of its focus (the world origin the camera looks
    /// at, on the flat map and the globe alike) over the depth of the
    /// point, clamped to `minimumPerspectiveScale...1`. A point at the
    /// focus or nearer keeps its size, one twice as far is half as big down
    /// to the minimum. A minimum of 1 keeps every point at its size.
    ///
    /// `anchorPositions` receives where each point draws in the render
    /// world the frame draws with (xyz, w zero). Zero for a point without
    /// a projection.
    ///
    /// `spans` limits the work to those points (`LabelActiveSpans`), the
    /// others keep what they had. Nil projects every point.
    ///
    /// A point farther from the camera than `maximumDistanceScale` times
    /// the camera's depth of its focus is out of reach: not in
    /// `horizonVisibility`, like one past the horizon, so its label fades
    /// out (`LabelDistanceRule.scale`).
    func projectWithHorizonVisibility(snapshot: TilePointToScreenPointSnapshot,
                                      frameContext: FrameContext,
                                      tileOriginData: [FlatTileOriginData],
                                      minimumPerspectiveScale: Float = 1,
                                      maximumDistanceScale: Float = .infinity,
                                      spans: [Range<Int>]? = nil,
                                      screenPoints: inout [ScreenPointOutput],
                                      horizonVisibility: inout [Bool],
                                      perspectiveScales: inout [Float],
                                      anchorPositions: inout [SIMD4<Float>]) {
        let count = snapshot.pointsCount
        if screenPoints.count != count {
            screenPoints = Array(repeating: ScreenPointOutput(position: .zero, depth: 0, visible: 0), count: count)
        }
        if horizonVisibility.count != count {
            horizonVisibility = Array(repeating: false, count: count)
        }
        if perspectiveScales.count != count {
            perspectiveScales = Array(repeating: 1, count: count)
        }
        if anchorPositions.count != count {
            anchorPositions = Array(repeating: .zero, count: count)
        }
        guard count > 0 else {
            return
        }
        let focusDepth = Self.focusDepth(frameContext: frameContext)
        let perspective = PerspectiveScale(focusDepth: focusDepth,
                                           minimum: minimumPerspectiveScale)
        let maximumDepth = focusDepth * max(maximumDistanceScale, 0)
        let spans = spans ?? [0..<count]

        switch frameContext.screenSpaceProjectionMode {
        case .flat:
            projectFlatScreenPoints(snapshot: snapshot,
                                    frameContext: frameContext,
                                    tileOriginData: tileOriginData,
                                    perspective: perspective,
                                    maximumDepth: maximumDepth,
                                    spans: spans,
                                    into: &screenPoints,
                                    inView: &horizonVisibility,
                                    perspectiveScales: &perspectiveScales,
                                    anchorPositions: &anchorPositions)
        case .globe:
            projectGlobe(snapshot: snapshot,
                         frameContext: frameContext,
                         perspective: perspective,
                         maximumDepth: maximumDepth,
                         spans: spans,
                         screenPoints: &screenPoints,
                         horizonVisibility: &horizonVisibility,
                         perspectiveScales: &perspectiveScales,
                         worldPositions: &anchorPositions)
        }
    }

    /// A label's shrink for its distance, from the clip-space w (the view
    /// depth) of its anchor.
    private struct PerspectiveScale {
        let focusDepth: Float
        let minimum: Float

        func scale(clipW: Float) -> Float {
            guard minimum < 1, focusDepth > 0, clipW > 0 else {
                return 1
            }
            return min(max(focusDepth / clipW, minimum), 1)
        }
    }

    /// The view depth of the point the camera looks at: the world origin,
    /// which the pan moves the map under on the flat map, and the globe's
    /// point under the camera.
    private static func focusDepth(frameContext: FrameContext) -> Float {
        let matrix = frameContext.screenSpaceProjectionMode == .flat
            ? frameContext.cameraMatrices.projectionView
            : frameContext.cameraUniform.matrix
        return (matrix * SIMD4<Float>(0, 0, 0, 1)).w
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
            // v grows from the NORTH edge, the flat render world is y-up.
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
        var perspectiveScales = Array(repeating: Float(1), count: snapshot.pointsCount)
        var anchorPositions = Array(repeating: SIMD4<Float>.zero, count: snapshot.pointsCount)
        var inView = Array(repeating: false, count: snapshot.pointsCount)
        projectFlatScreenPoints(snapshot: snapshot,
                                frameContext: frameContext,
                                tileOriginData: tileOriginData,
                                perspective: PerspectiveScale(focusDepth: 0, minimum: 1),
                                maximumDepth: .infinity,
                                spans: [0..<snapshot.pointsCount],
                                into: &outputs,
                                inView: &inView,
                                perspectiveScales: &perspectiveScales,
                                anchorPositions: &anchorPositions)
        return outputs
    }

    private func projectFlatScreenPoints(snapshot: TilePointToScreenPointSnapshot,
                                         frameContext: FrameContext,
                                         tileOriginData: [FlatTileOriginData],
                                         perspective: PerspectiveScale,
                                         maximumDepth: Float,
                                         spans: [Range<Int>],
                                         into outputs: inout [ScreenPointOutput],
                                         inView: inout [Bool],
                                         perspectiveScales: inout [Float],
                                         anchorPositions: inout [SIMD4<Float>]) {
        let viewport = SIMD2<Float>(Float(frameContext.drawSize.width), Float(frameContext.drawSize.height))
        let cameraMatrix = frameContext.cameraMatrices.projectionView
        let invisible = ScreenPointOutput(position: .zero, depth: 0, visible: 0)
        let count = snapshot.pointInputs.count
        let halfViewport = viewport * 0.5
        // The roofs stand as high as the buildings drawn under the label
        // have risen, by the tile and the quarter that draw them
        // (`BuildingFrameState.rise`): on the ground where
        // no buildings draw.
        let buildingRise = frameContext.state[BuildingFrameState.self].rise
        // The ground relief under each label, by its tile: the relief and
        // the world units a metre of it rises by, looked up once per tile
        // of the projection, nil for a tile whose terrain is not in.
        let groundRelief = frameContext.services.groundRelief
        var reliefByTile: [Tile: GroundReliefTileLift?] = [:]
        // The terrain each source's ground rises by: its placements'.
        let displacementBySource = groundRelief == nil || liftsByRelief == false
            ? [:] : frameContext.state[TilePlacementState.self].placeTilesContext.displacementBySource()
        func lift(tile: Tile, uv: SIMD2<Float>) -> Float {
            guard let groundRelief, liftsByRelief else { return 0 }
            let entry: GroundReliefTileLift?
            if let known = reliefByTile[tile] {
                entry = known
            } else {
                entry = GroundReliefTileLift(relief: groundRelief,
                                             tile: tile,
                                             terrain: displacementBySource[tile])
                reliefByTile[tile] = entry
            }
            return entry?.worldUnits(atTileUV: uv) ?? 0
        }

        snapshot.pointInputs.withUnsafeBufferPointer { inputs in
        snapshot.tileSlotVisibleTileIndices.withUnsafeBufferPointer { slots in
        tileOriginData.withUnsafeBufferPointer { origins in
        outputs.withUnsafeMutableBufferPointer { outputs in
        inView.withUnsafeMutableBufferPointer { inView in
        perspectiveScales.withUnsafeMutableBufferPointer { perspectiveScales in
        anchorPositions.withUnsafeMutableBufferPointer { anchorPositions in
          for span in spans {
            var index = span.lowerBound
            let end = min(span.upperBound, count)
            while index < end {
                let input = inputs[index]
                let tileSlotIndex = Int(input.tileSlotIndex)
                guard tileSlotIndex < slots.count else {
                    outputs[index] = invisible
                    inView[index] = false
                    anchorPositions[index] = .zero
                    index += 1
                    continue
                }
                let visibleTileIndex = Int(slots[tileSlotIndex])
                guard visibleTileIndex < origins.count else {
                    outputs[index] = invisible
                    inView[index] = false
                    anchorPositions[index] = .zero
                    index += 1
                    continue
                }

                let originData = origins[visibleTileIndex]
                // v grows from the NORTH edge, the flat render world is y-up.
                let local = SIMD2<Float>(input.uv.x * originData.size,
                                         (1.0 - input.uv.y) * originData.size)
                let worldPosition = originData.panRelativeOrigin + local
                // The roof is in the tile's 4096 units, the extrusion mesh's
                // scale, so the same tile size that places the point raises it
                // to the roof the building draws.
                let roofZ = input.roofHeight > 0 ? input.roofHeight * originData.size / 4096.0 : 0.0
                // The label naming the building draws on its roof, one of the
                // things inside it on the ground.
                let drawsOnRoof = input.liftsToRoof != 0
                let tile = Tile(x: Int(input.tile.x), y: Int(input.tile.y), z: Int(input.tile.z))
                // The relief under the label lifts it, roof or ground.
                var drawnZ: Float = lift(tile: tile, uv: input.uv)
                if drawsOnRoof {
                    drawnZ += roofZ * buildingRise.rise(tile: tile, uv: input.uv)
                }
                let clip = cameraMatrix * SIMD4<Float>(worldPosition.x, worldPosition.y, drawnZ, 1.0)
                // `screenPointFromClip` written out: this loop runs over
                // every label of the frame.
                if clip.w > 0 {
                    let inverseW = 1 / clip.w
                    let ndc = SIMD2<Float>(clip.x, clip.y) * inverseW
                    outputs[index] = ScreenPointOutput(position: (ndc + 1) * halfViewport,
                                                       depth: clip.z * inverseW,
                                                       visible: 1,
                                                       visibilityAlpha: 1)
                    // The flat map has no horizon: a point is in view where
                    // it projects within reach.
                    inView[index] = clip.w <= maximumDepth
                } else {
                    outputs[index] = invisible
                    inView[index] = false
                }
                perspectiveScales[index] = perspective.scale(clipW: clip.w)
                anchorPositions[index] = SIMD4<Float>(worldPosition.x, worldPosition.y, drawnZ, 0)
                index += 1
            }
          }
        }}}}}}}
    }

    private func projectGlobe(snapshot: TilePointToScreenPointSnapshot,
                              frameContext: FrameContext) -> TilePointScreenProjectionResult {
        var result = TilePointScreenProjectionResult(
            screenPoints: Array(repeating: ScreenPointOutput(position: .zero, depth: 0, visible: 0), count: snapshot.pointsCount),
            horizonVisibility: Array(repeating: false, count: snapshot.pointsCount))
        var perspectiveScales = Array(repeating: Float(1), count: snapshot.pointsCount)
        var worldPositions = Array(repeating: SIMD4<Float>.zero, count: snapshot.pointsCount)
        projectGlobe(snapshot: snapshot,
                     frameContext: frameContext,
                     perspective: PerspectiveScale(focusDepth: 0, minimum: 1),
                     spans: [0..<snapshot.pointsCount],
                     screenPoints: &result.screenPoints,
                     horizonVisibility: &result.horizonVisibility,
                     perspectiveScales: &perspectiveScales,
                     worldPositions: &worldPositions)
        return result
    }

    private func projectGlobe(snapshot: TilePointToScreenPointSnapshot,
                              frameContext: FrameContext,
                              perspective: PerspectiveScale,
                              maximumDepth: Float = .infinity,
                              spans: [Range<Int>],
                              screenPoints outputs: inout [ScreenPointOutput],
                              horizonVisibility: inout [Bool],
                              perspectiveScales: inout [Float],
                              worldPositions: inout [SIMD4<Float>]) {
        let constants = GeoScreenProjectionMath.FrameConstants(drawSize: frameContext.drawSize,
                                                               cameraUniform: frameContext.cameraUniform,
                                                               resolvedPresentation: frameContext.resolvedPresentation)

        let count = snapshot.pointInputs.count
        for span in spans {
          for index in span.clamped(to: 0..<count) {
            let projection = Self.projectGlobePoint(snapshot.pointInputs[index], constants: constants)
            outputs[index] = projection.screenPoint
            horizonVisibility[index] = projection.isOnVisibleGround && projection.clipW <= maximumDepth
            perspectiveScales[index] = perspective.scale(clipW: projection.clipW)
            worldPositions[index] = SIMD4<Float>(projection.worldPosition, 0)
          }
        }
    }

    /// A tile point on the globe, as one frame projects it.
    struct GlobePointProjection {
        var screenPoint: ScreenPointOutput
        /// Whether the ground under the point is drawn: on the near side
        /// of the sphere, and through the morph not on the part of the
        /// surface the unroll still hides.
        var isOnVisibleGround: Bool
        var clipW: Float
        var worldPosition: SIMD3<Float>
    }

    /// The share of the ground's visibility (`GeoScreenProjectionMath
    /// .globeVisibility`) from which a point counts as on visible ground.
    /// That visibility is soft, a half exactly on the sphere's horizon, and
    /// what stands on a tile point (a name, a tile's frame) shows or does
    /// not: it shows from the horizon inward.
    static let visibleGroundThreshold: Float = 0.5

    /// Projects one tile point on the globe, by the globe point every CPU
    /// projection shares (`GeoScreenProjectionMath.globeSurfacePoint`): the
    /// point stands where the ground's vertex stage draws that place, on
    /// the resting sphere and all through the morph.
    static func projectGlobePoint(_ input: TilePointInput,
                                  constants: GeoScreenProjectionMath.FrameConstants) -> GlobePointProjection {
        let zPow = powf(2.0, Float(input.tile.z))
        let size = 1.0 / zPow
        let normalizedWorldX = input.uv.x / zPow + size * Float(input.tile.x)
        let mercatorV = (Float(input.tile.y) + input.uv.y) / zPow
        let latitude = atan(sinh(Float.pi * (1.0 - 2.0 * mercatorV)))
        let longitude = normalizedWorldX * (2.0 * Float.pi) - Float.pi
        let cosLatitude = cos(latitude)
        let surface = GeoScreenProjectionMath.globeSurfacePoint(
            sphereUnit: SIMD3<Float>(cosLatitude * sin(longitude), sin(latitude), cosLatitude * cos(longitude)),
            normalizedWorldX: normalizedWorldX,
            mercatorYNormalized: Float(ImmersiveMapProjection.yMercatorNormalized(latitude: Double(latitude))),
            constants: constants)
        let clip = constants.cameraUniform.matrix * SIMD4<Float>(surface.worldPosition, 1.0)
        var screenPoint = GeoScreenProjectionMath.screenPointFromClip(clip: clip, viewportSize: constants.viewport)
        var isOnVisibleGround = false
        if screenPoint.visible != 0 {
            let visibility = GeoScreenProjectionMath.globeVisibility(worldPosition: surface.worldPosition,
                                                                     sphereWorldPosition: surface.sphereWorldPosition,
                                                                     flatWorldPosition: surface.flatWorldPosition,
                                                                     constants: constants)
            isOnVisibleGround = visibility.alpha >= visibleGroundThreshold
            screenPoint.visibilityAlpha = 1.0
        }
        return GlobePointProjection(screenPoint: screenPoint,
                                    isOnVisibleGround: isOnVisibleGround,
                                    clipW: clip.w,
                                    worldPosition: surface.worldPosition)
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
}

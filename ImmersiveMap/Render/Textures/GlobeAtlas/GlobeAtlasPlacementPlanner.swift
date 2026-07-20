// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import simd

struct GlobeAtlasPlacementPlanner {
    /// Кап анизотропии слота: слот обслуживает растянутую ось экранного следа,
    /// но не более чем в 4 раза детальнее сжатой оси. Чистый `max` давал полосе
    /// у горизонта гигантский слот (рябь при минификации и раздутый бюджет
    /// страниц), чистый `min` делал пиксельным ближний тайл, растянутый на весь
    /// экран по ширине.
    static let maximumSlotAnisotropy: Float = 4.0

    let pageSizePx: Int
    let qualityScale: Float

    init(pageSizePx: Int = 4096,
         qualityScale: Float = 1.0) {
        self.pageSizePx = pageSizePx
        self.qualityScale = max(0.25, qualityScale)
    }

    static func screenDemandPx(boundsPx: CGRect) -> Float {
        let stretchedSide = Float(max(boundsPx.width, boundsPx.height))
        let compressedSide = Float(min(boundsPx.width, boundsPx.height))
        return min(stretchedSide, maximumSlotAnisotropy * compressedSide)
    }

    static func makeCandidateForTesting(placementIndex: Int,
                                        placeTile: PlaceTile,
                                        screenBoundsPx: CGRect,
                                        pageSizePx: Int,
                                        qualityScale: Float = 1.0) -> GlobeAtlasCandidate {
        let demand = screenDemandPx(boundsPx: screenBoundsPx)
        return GlobeAtlasCandidate(placementIndex: placementIndex,
                                   placeTile: placeTile,
                                   screenDemandPx: demand,
                                   distanceToCamera: 0,
                                   desiredDepth: GlobeAtlasSlotDepth.desired(forScreenDemandPx: demand,
                                                                             pageSizePx: pageSizePx,
                                                                             qualityScale: qualityScale))
    }

    static func screenFootprintForTesting(projectedSamples: [(position: SIMD2<Float>,
                                                              depth: Float,
                                                              passesHorizon: Bool)],
                                          viewport: SIMD2<Float>) -> CGRect? {
        var minimumX = Float.greatestFiniteMagnitude
        var minimumY = Float.greatestFiniteMagnitude
        var maximumX = -Float.greatestFiniteMagnitude
        var maximumY = -Float.greatestFiniteMagnitude
        var hasVisibleSample = false

        for sample in projectedSamples where sample.passesHorizon {
            let clampedPosition = SIMD2<Float>(simd_clamp(sample.position.x, 0, viewport.x),
                                               simd_clamp(sample.position.y, 0, viewport.y))
            minimumX = min(minimumX, clampedPosition.x)
            minimumY = min(minimumY, clampedPosition.y)
            maximumX = max(maximumX, clampedPosition.x)
            maximumY = max(maximumY, clampedPosition.y)
            hasVisibleSample = true
        }

        guard hasVisibleSample else { return nil }
        return CGRect(x: CGFloat(minimumX),
                      y: CGFloat(minimumY),
                      width: CGFloat(max(1, maximumX - minimumX)),
                      height: CGFloat(max(1, maximumY - minimumY)))
    }

    func makeCandidates(placeTiles: [PlaceTile],
                        frameContext: FrameContext) -> [GlobeAtlasCandidate] {
        let texturePlaceTiles = placeTiles.map {
            GlobeTexturePlaceTile(placeTile: $0)
        }
        return makeCandidates(placeTiles: texturePlaceTiles,
                              frameContext: frameContext)
    }

    func makeCandidates(placeTiles: [GlobeTexturePlaceTile],
                        frameContext: FrameContext) -> [GlobeAtlasCandidate] {
        placeTiles.enumerated().compactMap { index, placeTile in
            guard let footprint = estimateScreenFootprint(placeTile: placeTile.placeTile,
                                                          frameContext: frameContext) else {
                return nil
            }

            let demand = Self.screenDemandPx(boundsPx: footprint.bounds)
            return GlobeAtlasCandidate(placementIndex: index,
                                       placeTile: placeTile.placeTile,
                                       screenDemandPx: demand,
                                       distanceToCamera: footprint.minimumDepth,
                                       desiredDepth: GlobeAtlasSlotDepth.desired(forScreenDemandPx: demand,
                                                                                 pageSizePx: pageSizePx,
                                                                                 qualityScale: qualityScale))
        }
    }

    func plan(candidates: [GlobeAtlasCandidate]) -> GlobeAtlasPlan {
        guard !candidates.isEmpty else { return .empty }

        let desiredDepths = Dictionary(uniqueKeysWithValues: candidates.map {
            ($0.placementIndex, desiredDepth(for: $0))
        })
        let baselinePlan = makePlan(candidates: candidates,
                                    depthsByPlacementIndex: desiredDepths)
        guard baselinePlan.skippedAllocationCount == 0 else {
            return baselinePlan
        }

        let pageBudget = baselinePlan.pageSummaries.count
        let pageBudgetAreaUnits = pageBudget * GlobeAtlasSlotDepth.depth0.areaUnitsAtMaximumDepth
        var selectedDepths = desiredDepths
        var selectedAreaUnits = selectedDepths.values.reduce(0) {
            $0 + $1.areaUnitsAtMaximumDepth
        }
        for candidate in candidates.sorted(by: shouldUpgradeBefore) {
            while let currentDepth = selectedDepths[candidate.placementIndex],
                  let largerDepth = currentDepth.largerSlotDepth {
                let trialAreaUnits = selectedAreaUnits
                    - currentDepth.areaUnitsAtMaximumDepth
                    + largerDepth.areaUnitsAtMaximumDepth
                guard trialAreaUnits <= pageBudgetAreaUnits else {
                    break
                }

                var trialDepths = selectedDepths
                trialDepths[candidate.placementIndex] = largerDepth
                let trialPlan = makePlan(candidates: candidates,
                                         depthsByPlacementIndex: trialDepths)
                guard trialPlan.skippedAllocationCount == 0,
                      trialPlan.allocations.count == candidates.count,
                      trialPlan.pageSummaries.count <= pageBudget else {
                    break
                }
                selectedDepths = trialDepths
                selectedAreaUnits = trialAreaUnits
            }
        }

        return makePlan(candidates: candidates,
                        depthsByPlacementIndex: selectedDepths)
    }

    private func makePlan(candidates: [GlobeAtlasCandidate],
                          depthsByPlacementIndex: [Int: GlobeAtlasSlotDepth]) -> GlobeAtlasPlan {
        var pages: [Page] = []
        var allocations: [GlobeAtlasAllocation] = []
        var downgradedAllocationCount = 0
        var skippedAllocationCount = 0
        let orderedCandidates = candidates.sorted {
            shouldPlaceBefore($0, $1, depthsByPlacementIndex: depthsByPlacementIndex)
        }

        for candidate in orderedCandidates {
            let depth = depthsByPlacementIndex[candidate.placementIndex] ?? desiredDepth(for: candidate)
            guard let allocation = allocate(candidate: candidate, depth: depth, pages: &pages) else {
                skippedAllocationCount += 1
                continue
            }

            if allocation.atlasDepth > desiredDepth(for: candidate) {
                downgradedAllocationCount += 1
            }
            allocations.append(allocation)
        }

        return GlobeAtlasPlan(allocations: allocations,
                              pageSummaries: pages.map(\.summary),
                              downgradedAllocationCount: downgradedAllocationCount,
                              skippedAllocationCount: skippedAllocationCount)
    }

    private func shouldPlaceBefore(_ lhs: GlobeAtlasCandidate,
                                   _ rhs: GlobeAtlasCandidate) -> Bool {
        shouldPlaceBefore(lhs,
                          rhs,
                          depthsByPlacementIndex: [
                            lhs.placementIndex: desiredDepth(for: lhs),
                            rhs.placementIndex: desiredDepth(for: rhs)
                          ])
    }

    private func shouldPlaceBefore(_ lhs: GlobeAtlasCandidate,
                                   _ rhs: GlobeAtlasCandidate,
                                   depthsByPlacementIndex: [Int: GlobeAtlasSlotDepth]) -> Bool {
        let lhsDepth = depthsByPlacementIndex[lhs.placementIndex] ?? desiredDepth(for: lhs)
        let rhsDepth = depthsByPlacementIndex[rhs.placementIndex] ?? desiredDepth(for: rhs)
        if lhsDepth != rhsDepth {
            return lhsDepth < rhsDepth
        }
        let lhsPriority = AtlasPriorityKey(candidate: lhs)
        let rhsPriority = AtlasPriorityKey(candidate: rhs)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        return lhs.placementIndex < rhs.placementIndex
    }

    private func shouldUpgradeBefore(_ lhs: GlobeAtlasCandidate,
                                     _ rhs: GlobeAtlasCandidate) -> Bool {
        let lhsPriority = AtlasPriorityKey(candidate: lhs)
        let rhsPriority = AtlasPriorityKey(candidate: rhs)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        return lhs.placementIndex < rhs.placementIndex
    }

    private func allocate(candidate: GlobeAtlasCandidate,
                          depth: GlobeAtlasSlotDepth,
                          pages: inout [Page]) -> GlobeAtlasAllocation? {
        for index in pages.indices {
            if let placedPosition = pages[index].add(depth: depth) {
                pages[index].allocatedSlotCount += 1
                return GlobeAtlasAllocation(candidate: candidate,
                                            pageIndex: pages[index].pageIndex,
                                            placedPosition: placedPosition,
                                            atlasDepth: depth,
                                            cellSizePx: depth.cellSize(pageSizePx: pageSizePx))
            }
        }

        let page = Page(pageIndex: pages.count)
        pages.append(page)
        guard let placedPosition = pages[pages.count - 1].add(depth: depth) else {
            return nil
        }
        pages[pages.count - 1].allocatedSlotCount += 1
        return GlobeAtlasAllocation(candidate: candidate,
                                    pageIndex: page.pageIndex,
                                    placedPosition: placedPosition,
                                    atlasDepth: depth,
                                    cellSizePx: depth.cellSize(pageSizePx: pageSizePx))
    }

    private func desiredDepth(for candidate: GlobeAtlasCandidate) -> GlobeAtlasSlotDepth {
        guard qualityScale != 1.0 else { return candidate.desiredDepth }
        return GlobeAtlasSlotDepth.desired(forScreenDemandPx: candidate.screenDemandPx,
                                           pageSizePx: pageSizePx,
                                           qualityScale: qualityScale)
    }

    private func estimateScreenFootprint(placeTile: PlaceTile,
                                         frameContext: FrameContext) -> ScreenFootprint? {
        let viewport = SIMD2<Float>(Float(frameContext.drawSize.width),
                                    Float(frameContext.drawSize.height))
        let cameraUniform = frameContext.cameraUniform
        let constants = GlobeAtlasProjectionConstants(globe: frameContext.globeRenderUniform)
        var minimumX = Float.greatestFiniteMagnitude
        var minimumY = Float.greatestFiniteMagnitude
        var maximumX = -Float.greatestFiniteMagnitude
        var maximumY = -Float.greatestFiniteMagnitude
        var minimumDepth = Float.greatestFiniteMagnitude
        var hasVisibleSample = false

        for uv in sampleUVs(for: placeTile.placeIn.tile, constants: constants) {
            let input = TilePointInput(uv: uv,
                                       tile: tileVector(placeTile.placeIn.tile))
            let projection = globeProjectTileUV(input: input,
                                                cameraUniform: cameraUniform,
                                                constants: constants)
            var output = screenPointFromClip(clip: projection.clip,
                                             viewportSize: viewport)
            guard output.visible != 0,
                  output.position.x.isFinite,
                  output.position.y.isFinite,
                  output.depth.isFinite else {
                continue
            }

            if output.visible != 0 {
                let visibility = globeProjectionVisibility(worldPosition: projection.worldPosition,
                                                           cameraUniform: cameraUniform,
                                                           constants: constants)
                output.visible = visibility.visible ? output.visible : 0
            }
            guard output.visible != 0 else {
                continue
            }

            let clampedPosition = clampToViewport(output.position, viewportSize: viewport)
            minimumX = min(minimumX, clampedPosition.x)
            minimumY = min(minimumY, clampedPosition.y)
            maximumX = max(maximumX, clampedPosition.x)
            maximumY = max(maximumY, clampedPosition.y)
            minimumDepth = min(minimumDepth, output.depth)
            hasVisibleSample = true
        }

        guard hasVisibleSample else {
            return nil
        }

        guard maximumX > minimumX || maximumY > minimumY else {
            let bounds = CGRect(x: CGFloat(minimumX),
                                y: CGFloat(minimumY),
                                width: 1,
                                height: 1)
            return ScreenFootprint(bounds: bounds,
                                   minimumDepth: minimumDepth)
        }

        let width = maximumX - minimumX
        let height = maximumY - minimumY
        guard width.isFinite, height.isFinite else {
            return nil
        }

        let bounds = CGRect(x: CGFloat(minimumX),
                            y: CGFloat(minimumY),
                            width: CGFloat(width),
                            height: CGFloat(height))
        return ScreenFootprint(bounds: bounds,
                               minimumDepth: minimumDepth)
    }

    private func sampleUVs(for tile: Tile,
                           constants: GlobeAtlasProjectionConstants) -> [SIMD2<Float>] {
        guard let centerUV = centerFacingUV(for: tile, constants: constants) else {
            return Self.sampleUVs
        }

        return Self.sampleUVs + [centerUV]
    }

    private func centerFacingUV(for tile: Tile,
                                constants: GlobeAtlasProjectionConstants) -> SIMD2<Float>? {
        let zPow = powf(2.0, Float(tile.z))
        let centerLongitude = -constants.panLongitude
        let normalizedWorldX = Float(
            ImmersiveMapProjection.wrapNormalizedWorldX(Double((centerLongitude + .pi) / (2.0 * .pi)))
        )
        let mercatorY = Float(ImmersiveMapProjection.yMercatorNormalized(latitude: Double(constants.panLatitude)))
        let normalizedWorldY = (1.0 - mercatorY) * 0.5
        let localX = normalizedWorldX * zPow - Float(tile.x)
        let localY = normalizedWorldY * zPow - Float(tile.y)
        let epsilon: Float = 0.00001

        guard localX >= -epsilon,
              localX <= 1.0 + epsilon,
              localY >= -epsilon,
              localY <= 1.0 + epsilon else {
            return nil
        }

        return SIMD2<Float>(simd_clamp(localX, 0.0, 1.0),
                            simd_clamp(localY, 0.0, 1.0))
    }

    private func tileVector(_ tile: Tile) -> SIMD3<Int32> {
        SIMD3<Int32>(Int32(tile.x), Int32(tile.y), Int32(tile.z))
    }

    private func clampToViewport(_ position: SIMD2<Float>,
                                 viewportSize: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(simd_clamp(position.x, 0, viewportSize.x),
                     simd_clamp(position.y, 0, viewportSize.y))
    }

    private func screenPointFromClip(clip: SIMD4<Float>,
                                     viewportSize: SIMD2<Float>) -> ScreenPointOutput {
        guard clip.w > 0.0 else {
            return ScreenPointOutput(position: .zero,
                                     depth: 0.0,
                                     visible: 0,
                                     visibilityAlpha: 0.0)
        }

        let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
        let depth = clip.z / clip.w
        let position = (ndc * 0.5 + 0.5) * viewportSize
        return ScreenPointOutput(position: position,
                                 depth: depth,
                                 visible: 1,
                                 visibilityAlpha: 1.0)
    }

    private func globeProjectTileUV(input: TilePointInput,
                                    cameraUniform: CameraUniform,
                                    constants: GlobeAtlasProjectionConstants) -> GlobeAtlasProjectionResult {
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
                                    constants: GlobeAtlasProjectionConstants) -> GlobeAtlasProjectionResult {
        let sphereWorldPosition = constants.rotatedSphereWorldPosition(latitude: latitude,
                                                                       longitude: longitude)
        let flatWorldPosition = constants.flatWorldPosition(latitude: latitude,
                                                            longitude: longitude)
        let transition = constants.globe.transition
        let worldPosition = sphereWorldPosition + (flatWorldPosition - sphereWorldPosition) * transition
        let clip = cameraUniform.matrix * SIMD4<Float>(worldPosition, 1.0)
        return GlobeAtlasProjectionResult(clip: clip,
                                          worldPosition: worldPosition)
    }

    private func globeProjectionVisibility(worldPosition: SIMD3<Float>,
                                           cameraUniform: CameraUniform,
                                           constants: GlobeAtlasProjectionConstants) -> (visible: Bool, alpha: Float) {
        let globeCenter = SIMD3<Float>(0.0, 0.0, -constants.globe.radius)
        let toCamera = cameraUniform.eye - globeCenter
        if simd_length(toCamera) <= 0.0 || constants.globe.transition >= 0.95 {
            return (true, 1.0)
        }

        let toCameraLength = simd_length(toCamera)
        let radius = max(constants.globe.radius, 1e-6)
        let dotToCamera = simd_dot(worldPosition - globeCenter, toCamera)
        let normalization = max(toCameraLength * radius, 1e-6)
        let normalizedDot = dotToCamera / normalization
        let normalizedThreshold = constants.horizonThreshold / normalization
        let visibilityDelta = normalizedDot - normalizedThreshold

        if visibilityDelta <= -Self.globeHorizonFadeBandWidth {
            return (false, 0.0)
        }

        let alpha = smoothstep(edge0: -Self.globeHorizonFadeBandWidth,
                               edge1: Self.globeHorizonFadeBandWidth,
                               x: visibilityDelta)
        return (true, alpha)
    }

    private func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = simd_clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)
    }

    private static let globeHorizonFadeBandWidth: Float = 0.03

    private static let sampleUVs: [SIMD2<Float>] = [
        SIMD2<Float>(0.0, 0.0), SIMD2<Float>(0.5, 0.0), SIMD2<Float>(1.0, 0.0),
        SIMD2<Float>(0.0, 0.5), SIMD2<Float>(0.5, 0.5), SIMD2<Float>(1.0, 0.5),
        SIMD2<Float>(0.0, 1.0), SIMD2<Float>(0.5, 1.0), SIMD2<Float>(1.0, 1.0)
    ]
}

private struct ScreenFootprint {
    let bounds: CGRect
    let minimumDepth: Float
}

private struct AtlasPriorityKey: Comparable, Equatable {
    private static let screenDemandBucketPx: Float = 64
    private static let distanceBucket: Float = 0.05

    let replacementRank: Int
    let screenDemandBucket: Int
    let distanceBucket: Int
    let sourceTile: Tile
    let targetTile: Tile
    let lodKind: TileLodKind

    init(candidate: GlobeAtlasCandidate) {
        let placeTile = candidate.placeTile
        replacementRank = Self.replacementRank(for: placeTile)
        screenDemandBucket = Self.bucket(candidate.screenDemandPx,
                                         bucketSize: Self.screenDemandBucketPx)
        distanceBucket = Self.bucket(candidate.distanceToCamera,
                                     bucketSize: Self.distanceBucket)
        sourceTile = placeTile.metalTile.tile
        targetTile = placeTile.placeIn.tile
        lodKind = placeTile.lodKind
    }

    static func < (lhs: AtlasPriorityKey, rhs: AtlasPriorityKey) -> Bool {
        if lhs.replacementRank != rhs.replacementRank {
            return lhs.replacementRank < rhs.replacementRank
        }
        if lhs.screenDemandBucket != rhs.screenDemandBucket {
            return lhs.screenDemandBucket > rhs.screenDemandBucket
        }
        if lhs.distanceBucket != rhs.distanceBucket {
            return lhs.distanceBucket < rhs.distanceBucket
        }
        if lhs.sourceTile.z != rhs.sourceTile.z {
            return lhs.sourceTile.z < rhs.sourceTile.z
        }
        if lhs.sourceTile.x != rhs.sourceTile.x {
            return lhs.sourceTile.x < rhs.sourceTile.x
        }
        if lhs.sourceTile.y != rhs.sourceTile.y {
            return lhs.sourceTile.y < rhs.sourceTile.y
        }
        if lhs.targetTile.z != rhs.targetTile.z {
            return lhs.targetTile.z < rhs.targetTile.z
        }
        if lhs.targetTile.x != rhs.targetTile.x {
            return lhs.targetTile.x < rhs.targetTile.x
        }
        if lhs.targetTile.y != rhs.targetTile.y {
            return lhs.targetTile.y < rhs.targetTile.y
        }
        return lhs.lodKind.rawValue < rhs.lodKind.rawValue
    }

    private static func replacementRank(for placeTile: PlaceTile) -> Int {
        if placeTile.lodKind == .retainedReplacement || placeTile.metalTile.tile != placeTile.placeIn.tile {
            return 0
        }
        if placeTile.lodKind == .coarseSubstitute {
            return 1
        }
        return 2
    }

    private static func bucket(_ value: Float,
                               bucketSize: Float) -> Int {
        guard value.isFinite else { return 0 }
        let normalized = value / bucketSize
        if normalized >= Float(Int.max) {
            return Int.max
        }
        if normalized <= Float(Int.min) {
            return Int.min
        }
        return Int(normalized.rounded(.down))
    }
}

private struct GlobeAtlasProjectionResult {
    let clip: SIMD4<Float>
    let worldPosition: SIMD3<Float>
}

private struct GlobeAtlasProjectionConstants {
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
        self.rotationMatrix = GlobeAtlasProjectionConstants.makeRotationMatrix(panLatitude: panLatitude,
                                                                               panLongitude: panLongitude)
        let horizonFade = GlobeAtlasProjectionConstants.smoothstep(edge0: 0.8,
                                                                   edge1: 0.95,
                                                                   x: globe.transition)
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

    private static func smoothstep(edge0: Float,
                                   edge1: Float,
                                   x: Float) -> Float {
        let t = simd_clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)
    }
}

private struct Page {
    let pageIndex: Int
    var tree = GlobeTileTextureTree()
    var allocatedSlotCount = 0

    var summary: GlobeAtlasPageSummary {
        GlobeAtlasPageSummary(pageIndex: pageIndex,
                              allocatedSlotCount: allocatedSlotCount)
    }

    mutating func add(depth: GlobeAtlasSlotDepth) -> PlacedPos? {
        tree.addNewValue(value: TextureValue(), depth: depth.rawValue)
    }
}

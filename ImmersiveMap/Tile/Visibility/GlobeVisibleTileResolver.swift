// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GlobeVisibleTileResolver.swift
//  ImmersiveMap
//

import QuartzCore
import simd

struct GlobeCullingMetrics {
    static let zero = GlobeCullingMetrics(duration: 0,
                                          visitedNodeCount: 0,
                                          frustumRejectCount: 0,
                                          horizonRejectCount: 0,
                                          acceptedLeafTileCount: 0,
                                          acceptedWholeSubtreeCount: 0)

    var duration: TimeInterval
    var visitedNodeCount: Int
    var frustumRejectCount: Int
    var horizonRejectCount: Int
    var acceptedLeafTileCount: Int
    var acceptedWholeSubtreeCount: Int
}

struct GlobeVisibleTileResolution {
    let visibleTiles: [VisibleTile]
    let metrics: GlobeCullingMetrics
}

protocol GlobeVisibleTileResolving {
    func resolveVisibleTiles(targetZoom: Int,
                             globe: GlobeUniform,
                             cameraFrustum: Frustum?,
                             cameraEye: SIMD3<Float>) -> GlobeVisibleTileResolution
}

typealias GlobeNodeVisibilityEvaluator = (Tile, Int, Frustum, GlobeVisibilityInputs) -> GlobeNodeVisibilityEvaluation

final class GlobeVisibleTileResolver: GlobeVisibleTileResolving {
    private let visibilityEvaluationOverride: GlobeNodeVisibilityEvaluator?
    private let transitionLowZoomFallbackLimit = 3

    init(visibilityEvaluationOverride: GlobeNodeVisibilityEvaluator? = nil) {
        self.visibilityEvaluationOverride = visibilityEvaluationOverride
    }

    func resolveVisibleTiles(targetZoom: Int,
                             globe: GlobeUniform,
                             cameraFrustum: Frustum?,
                             cameraEye: SIMD3<Float>) -> GlobeVisibleTileResolution {
        let startTime = CACurrentMediaTime()
        guard targetZoom >= 0,
              let frustum = cameraFrustum else {
            return GlobeVisibleTileResolution(visibleTiles: [],
                                              metrics: .zero)
        }

        let inputs = GlobeVisibilityModel.makeInputs(globe: globe,
                                                     cameraEye: cameraEye)
        var visibleTiles: [VisibleTile] = []
        visibleTiles.reserveCapacity(estimatedVisibleTileCapacity(targetZoom: targetZoom))
        var metrics = GlobeCullingMetrics.zero
        traverse(tile: Tile(x: 0, y: 0, z: 0),
                 targetZoom: targetZoom,
                 frustum: frustum,
                 inputs: inputs,
                 visibleTiles: &visibleTiles,
                 metrics: &metrics)
        metrics.duration = CACurrentMediaTime() - startTime
        return GlobeVisibleTileResolution(visibleTiles: visibleTiles,
                                          metrics: metrics)
    }

    private func traverse(tile: Tile,
                          targetZoom: Int,
                          frustum: Frustum,
                          inputs: GlobeVisibilityInputs,
                          visibleTiles: inout [VisibleTile],
                          metrics: inout GlobeCullingMetrics) {
        metrics.visitedNodeCount += 1

        if inputs.transition > 0,
            targetZoom <= transitionLowZoomFallbackLimit {
            acceptLeafDescendants(of: tile,
                                  targetZoom: targetZoom,
                                  visibleTiles: &visibleTiles,
                                  metrics: &metrics)
            return
        }

        switch evaluateVisibility(for: tile,
                                  targetZoom: targetZoom,
                                  frustum: frustum,
                                  inputs: inputs) {
        case .rejectFrustum:
            metrics.frustumRejectCount += 1
            return
        case .rejectHorizon:
            metrics.horizonRejectCount += 1
            return
        case .acceptWholeSubtree:
            metrics.acceptedWholeSubtreeCount += 1
            acceptLeafDescendants(of: tile,
                                  targetZoom: targetZoom,
                                  visibleTiles: &visibleTiles,
                                  metrics: &metrics)
            return
        case .descend:
            break
        }

        if tile.z == targetZoom {
            visibleTiles.append(VisibleTile(tile: tile))
            metrics.acceptedLeafTileCount += 1
            return
        }

        let childZ = tile.z + 1
        let childX = tile.x * 2
        let childY = tile.y * 2
        traverse(tile: Tile(x: childX, y: childY, z: childZ),
                 targetZoom: targetZoom,
                 frustum: frustum,
                 inputs: inputs,
                 visibleTiles: &visibleTiles,
                 metrics: &metrics)
        traverse(tile: Tile(x: childX + 1, y: childY, z: childZ),
                 targetZoom: targetZoom,
                 frustum: frustum,
                 inputs: inputs,
                 visibleTiles: &visibleTiles,
                 metrics: &metrics)
        traverse(tile: Tile(x: childX, y: childY + 1, z: childZ),
                 targetZoom: targetZoom,
                 frustum: frustum,
                 inputs: inputs,
                 visibleTiles: &visibleTiles,
                 metrics: &metrics)
        traverse(tile: Tile(x: childX + 1, y: childY + 1, z: childZ),
                 targetZoom: targetZoom,
                 frustum: frustum,
                 inputs: inputs,
                 visibleTiles: &visibleTiles,
                 metrics: &metrics)
    }

    private func acceptLeafDescendants(of tile: Tile,
                                       targetZoom: Int,
                                       visibleTiles: inout [VisibleTile],
                                       metrics: inout GlobeCullingMetrics) {
        if tile.z == targetZoom {
            visibleTiles.append(VisibleTile(tile: tile))
            metrics.acceptedLeafTileCount += 1
            return
        }

        let childZ = tile.z + 1
        let childX = tile.x * 2
        let childY = tile.y * 2
        acceptLeafDescendants(of: Tile(x: childX, y: childY, z: childZ),
                              targetZoom: targetZoom,
                              visibleTiles: &visibleTiles,
                              metrics: &metrics)
        acceptLeafDescendants(of: Tile(x: childX + 1, y: childY, z: childZ),
                              targetZoom: targetZoom,
                              visibleTiles: &visibleTiles,
                              metrics: &metrics)
        acceptLeafDescendants(of: Tile(x: childX, y: childY + 1, z: childZ),
                              targetZoom: targetZoom,
                              visibleTiles: &visibleTiles,
                              metrics: &metrics)
        acceptLeafDescendants(of: Tile(x: childX + 1, y: childY + 1, z: childZ),
                              targetZoom: targetZoom,
                              visibleTiles: &visibleTiles,
                              metrics: &metrics)
    }

    private func evaluateVisibility(for tile: Tile,
                                    targetZoom: Int,
                                    frustum: Frustum,
                                    inputs: GlobeVisibilityInputs) -> GlobeNodeVisibilityEvaluation {
        if let visibilityEvaluationOverride {
            return visibilityEvaluationOverride(tile, targetZoom, frustum, inputs)
        }

        let shouldRejectAtZoom = tile.z >= minimumRejectZoom(targetZoom: targetZoom,
                                                             transition: inputs.transition)
        let needsWholeSubtreeEvaluation = tile.z < targetZoom

        guard shouldRejectAtZoom || needsWholeSubtreeEvaluation else {
            return .descend
        }

        let bound = GlobeVisibilityModel.tileBound(tile: tile, inputs: inputs)

        if shouldRejectAtZoom,
           frustum.isSphereVisible(center: bound.center, radius: bound.radius) == false {
            return .rejectFrustum
        }

        if shouldRejectAtZoom,
           GlobeVisibilityModel.tileMayPassHorizon(bound: bound, inputs: inputs) == false {
            return .rejectHorizon
        }

        if needsWholeSubtreeEvaluation,
           frustum.containsSphere(center: bound.center, radius: bound.radius),
           GlobeVisibilityModel.tilePassesHorizonEntirely(bound: bound, inputs: inputs) {
            return .acceptWholeSubtree
        }

        return .descend
    }

    private func minimumRejectZoom(targetZoom: Int,
                                   transition: Float) -> Int {
        min(targetZoom, transition > 0 ? 4 : 3)
    }

    private func estimatedVisibleTileCapacity(targetZoom: Int) -> Int {
        let safeExponent = min(targetZoom * 2, 12)
        return max(4, 1 << safeExponent)
    }
}

enum GlobeNodeVisibilityEvaluation {
    case rejectFrustum
    case rejectHorizon
    case descend
    case acceptWholeSubtree
}

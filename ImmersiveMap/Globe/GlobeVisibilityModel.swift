// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GlobeVisibilityModel.swift
//  ImmersiveMap
//

import simd

struct GlobeVisibilityInputs {
    let globe: GlobeUniform
    let cameraEye: SIMD3<Float>
    let globeCenter: SIMD3<Float>
    let transition: Float
    let rotation: simd_float4x4
    let globeToCamera: SIMD3<Float>
    let globeToCameraLength: Float
    let horizonThreshold: Float
}

struct GlobeTileVisibilityBound {
    let center: SIMD3<Float>
    let radius: Float
}

struct GlobeTileStaticVisibilityBound {
    let centerDirection: SIMD3<Float>
    let radiusScale: Float
}

enum GlobeVisibilityModel {
    private static let staticBoundsCache = GlobeTileStaticBoundsCache()

    static func makeInputs(globe: GlobeUniform,
                           cameraEye: SIMD3<Float>) -> GlobeVisibilityInputs {
        let panLatitude = Float(globe.panY) * Float(ImmersiveMapProjection.maxMercatorLatitude)
        let panLongitude = Float(globe.panX) * Float.pi
        let rotation = makeRotationMatrix(latitude: panLatitude, longitude: panLongitude)
        let globeCenter = SIMD3<Float>(0, 0, -globe.radius)
        let globeToCamera = cameraEye - globeCenter
        return GlobeVisibilityInputs(globe: globe,
                                     cameraEye: cameraEye,
                                     globeCenter: globeCenter,
                                     transition: globe.transition,
                                     rotation: rotation,
                                     globeToCamera: globeToCamera,
                                     globeToCameraLength: simd_length(globeToCamera),
                                     horizonThreshold: horizonThreshold(globe: globe))
    }

    static func tileBound(tile: Tile,
                          inputs: GlobeVisibilityInputs) -> GlobeTileVisibilityBound {
        let staticBound = staticBoundGeometry(for: tile)
        return tileBound(staticBound: staticBound, inputs: inputs)
    }

    static func staticBoundGeometry(for tile: Tile) -> GlobeTileStaticVisibilityBound {
        staticBoundsCache.bound(for: tile)
    }

    static func tileBound(staticBound: GlobeTileStaticVisibilityBound,
                          inputs: GlobeVisibilityInputs) -> GlobeTileVisibilityBound {
        let rotatedDirection = SIMD4<Float>(staticBound.centerDirection, 0) * inputs.rotation
        let sphereCenter = inputs.globeCenter + (rotatedDirection.xyz * inputs.globe.radius)
        return GlobeTileVisibilityBound(center: sphereCenter,
                                        radius: inputs.globe.radius * staticBound.radiusScale)
    }

    static func pointPassesHorizon(worldPosition: SIMD3<Float>,
                                   inputs: GlobeVisibilityInputs) -> Bool {
        if inputs.globeToCameraLength <= 0 || horizonRejectEnabled(for: inputs.transition) == false {
            return true
        }

        let dotToCamera = simd_dot(worldPosition - inputs.globeCenter, inputs.globeToCamera)
        return dotToCamera >= inputs.horizonThreshold
    }

    static func tileMayPassHorizon(bound: GlobeTileVisibilityBound,
                                   inputs: GlobeVisibilityInputs) -> Bool {
        if inputs.globeToCameraLength <= 0 || horizonRejectEnabled(for: inputs.transition) == false {
            return true
        }

        let centerDot = simd_dot(bound.center - inputs.globeCenter, inputs.globeToCamera)
        let maxDotInsideBound = centerDot + (bound.radius * inputs.globeToCameraLength)
        return maxDotInsideBound >= inputs.horizonThreshold
    }

    static func tilePassesHorizonEntirely(bound: GlobeTileVisibilityBound,
                                          inputs: GlobeVisibilityInputs) -> Bool {
        if inputs.globeToCameraLength <= 0 || horizonRejectEnabled(for: inputs.transition) == false {
            return true
        }

        let centerDot = simd_dot(bound.center - inputs.globeCenter, inputs.globeToCamera)
        let minDotInsideBound = centerDot - (bound.radius * inputs.globeToCameraLength)
        return minDotInsideBound >= inputs.horizonThreshold
    }

    static func horizonRejectEnabled(for transition: Float) -> Bool {
        transition <= 0
    }

    fileprivate static func makeStaticBoundGeometry(for tile: Tile) -> GlobeTileStaticVisibilityBound {
        let coordinateBounds = makeCoordinateBounds(for: tile)
        let centerLatitude = 0.5 * (coordinateBounds.northLatitude + coordinateBounds.southLatitude)
        let centerLongitude = unwrapLongitudeMidpoint(west: coordinateBounds.westLongitude,
                                                      east: coordinateBounds.eastLongitude)
        let centerDirection = unitSphereDirection(latitude: centerLatitude,
                                                  longitude: centerLongitude)

        if coordinateBounds.tile.z == 0 {
            return GlobeTileStaticVisibilityBound(centerDirection: centerDirection,
                                                  radiusScale: 2.0)
        }

        let cornerDirections = [
            unitSphereDirection(latitude: coordinateBounds.northLatitude, longitude: coordinateBounds.westLongitude),
            unitSphereDirection(latitude: coordinateBounds.northLatitude, longitude: coordinateBounds.eastLongitude),
            unitSphereDirection(latitude: coordinateBounds.southLatitude, longitude: coordinateBounds.westLongitude),
            unitSphereDirection(latitude: coordinateBounds.southLatitude, longitude: coordinateBounds.eastLongitude)
        ]

        let maxAngle = cornerDirections.reduce(Float.zero) { current, direction in
            max(current, angularDistance(centerDirection, direction))
        }
        return GlobeTileStaticVisibilityBound(centerDirection: centerDirection,
                                              radiusScale: 2.0 * sin(maxAngle * 0.5))
    }

    private static func horizonThreshold(globe: GlobeUniform) -> Float {
        globe.radius * globe.radius
    }

    private static func makeCoordinateBounds(for tile: Tile) -> TileCoordinateBounds {
        let scale = Float(1 << tile.z)
        let westWorldX = Float(tile.x) / scale
        let eastWorldX = Float(tile.x + 1) / scale
        let northWorldY = Float(tile.y) / scale
        let southWorldY = Float(tile.y + 1) / scale

        return TileCoordinateBounds(tile: tile,
                                    northLatitude: Float(ImmersiveMapProjection.latitude(fromNormalizedWorldY: Double(northWorldY))),
                                    southLatitude: Float(ImmersiveMapProjection.latitude(fromNormalizedWorldY: Double(southWorldY))),
                                    westLongitude: Float(ImmersiveMapProjection.longitude(fromNormalizedWorldX: Double(westWorldX))),
                                    eastLongitude: Float(ImmersiveMapProjection.longitude(fromNormalizedWorldX: Double(eastWorldX))))
    }

    private static func unwrapLongitudeMidpoint(west: Float,
                                                east: Float) -> Float {
        let eastUnwrapped = east >= west ? east : east + (2.0 * Float.pi)
        let midpoint = 0.5 * (west + eastUnwrapped)
        if midpoint > Float.pi {
            return midpoint - (2.0 * Float.pi)
        }
        return midpoint
    }

    private static func makeRotationMatrix(latitude: Float,
                                           longitude: Float) -> simd_float4x4 {
        let cx = cos(-latitude)
        let sx = sin(-latitude)
        let cy = cos(-longitude)
        let sy = sin(-longitude)

        return simd_float4x4(
            SIMD4<Float>(cy, 0, -sy, 0),
            SIMD4<Float>(sy * sx, cx, cy * sx, 0),
            SIMD4<Float>(sy * cx, -sx, cy * cx, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private static func unitSphereDirection(latitude: Float,
                                            longitude: Float) -> SIMD3<Float> {
        let phi = latitude - (Float.pi * 0.5)
        let theta = longitude + Float.pi
        return simd_normalize(SIMD3<Float>(sin(phi) * sin(theta),
                                           cos(phi),
                                           sin(phi) * cos(theta)))
    }

    private static func angularDistance(_ lhs: SIMD3<Float>,
                                        _ rhs: SIMD3<Float>) -> Float {
        let clamped = min(max(simd_dot(lhs, rhs), -1.0), 1.0)
        return acos(clamped)
    }
}

private struct TileCoordinateBounds {
    let tile: Tile
    let northLatitude: Float
    let southLatitude: Float
    let westLongitude: Float
    let eastLongitude: Float
}

private final class GlobeTileStaticBoundsCache {
    private var boundsByTile: [Tile: GlobeTileStaticVisibilityBound] = [:]

    func bound(for tile: Tile) -> GlobeTileStaticVisibilityBound {
        if let cachedBound = boundsByTile[tile] {
            return cachedBound
        }

        let bound = GlobeVisibilityModel.makeStaticBoundGeometry(for: tile)
        boundsByTile[tile] = bound
        return bound
    }
}

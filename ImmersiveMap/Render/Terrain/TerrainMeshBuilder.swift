// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

enum TerrainMeshBuilder {
    static func buildFlatMesh(tile: Tile,
                              heightGrid: TerrainHeightGrid,
                              resolution: Int,
                              exaggeration: Float,
                              heightScale: Float) -> TerrainMesh {
        let count = max(resolution, 2)
        var vertices: [TerrainMesh.Vertex] = []
        vertices.reserveCapacity(count * count)
        let maxIndex = Float(count - 1)

        for row in 0..<count {
            for column in 0..<count {
                let u = Float(column) / maxIndex
                let v = Float(row) / maxIndex
                let height = scaledHeight(grid: heightGrid,
                                          u: u,
                                          v: v,
                                          exaggeration: exaggeration,
                                          heightScale: heightScale)
                let position = SIMD3<Float>(u * 4096.0,
                                            (1.0 - v) * 4096.0,
                                            height)
                vertices.append(TerrainMesh.Vertex(position: position,
                                                   normal: SIMD3<Float>(0, 0, 1),
                                                   color: color(forHeight: height)))
            }
        }

        return TerrainMesh(tile: tile,
                           vertices: vertices,
                           indices: gridIndices(resolution: count))
    }

    // Builds unrotated sphere-space terrain. Current globe pan, transition, and center translation
    // are frame-dependent and belong to the draw path, matching the existing globe surface shader.
    static func buildGlobeMesh(tile: Tile,
                               heightGrid: TerrainHeightGrid,
                               resolution: Int,
                               globeRadius: Float,
                               exaggeration: Float,
                               heightScale: Float) -> TerrainMesh {
        let count = max(resolution, 2)
        var vertices: [TerrainMesh.Vertex] = []
        vertices.reserveCapacity(count * count)
        let maxIndex = Float(count - 1)

        for row in 0..<count {
            for column in 0..<count {
                let u = Float(column) / maxIndex
                let v = Float(row) / maxIndex
                let height = scaledHeight(grid: heightGrid,
                                          u: u,
                                          v: v,
                                          exaggeration: exaggeration,
                                          heightScale: heightScale)
                let normal = globeNormal(tile: tile, u: Double(u), v: Double(v))
                let position = normal * (globeRadius + height)
                vertices.append(TerrainMesh.Vertex(position: position,
                                                   normal: normal,
                                                   color: color(forHeight: height)))
            }
        }

        return TerrainMesh(tile: tile,
                           vertices: vertices,
                           indices: gridIndices(resolution: count))
    }

    private static func sampleNearest(grid: TerrainHeightGrid, u: Float, v: Float) -> Float {
        let x = Int((u * Float(grid.width - 1)).rounded())
        let y = Int((v * Float(grid.height - 1)).rounded())
        return grid.heightAt(x: x, y: y)
    }

    private static func scaledHeight(grid: TerrainHeightGrid,
                                     u: Float,
                                     v: Float,
                                     exaggeration: Float,
                                     heightScale: Float) -> Float {
        sampleNearest(grid: grid, u: u, v: v) * exaggeration * heightScale
    }

    private static func gridIndices(resolution: Int) -> [UInt32] {
        var indices: [UInt32] = []
        indices.reserveCapacity((resolution - 1) * (resolution - 1) * 6)
        for row in 0..<(resolution - 1) {
            for column in 0..<(resolution - 1) {
                let topLeft = UInt32(row * resolution + column)
                let topRight = topLeft + 1
                let bottomLeft = UInt32((row + 1) * resolution + column)
                let bottomRight = bottomLeft + 1
                indices.append(topLeft)
                indices.append(bottomLeft)
                indices.append(topRight)
                indices.append(topRight)
                indices.append(bottomLeft)
                indices.append(bottomRight)
            }
        }
        return indices
    }

    private static func globeNormal(tile: Tile, u: Double, v: Double) -> SIMD3<Float> {
        let tilesCount = Double(1 << tile.z)
        let normalizedX = (Double(tile.x) + u) / tilesCount
        let normalizedY = (Double(tile.y) + v) / tilesCount
        let longitude = ImmersiveMapProjection.longitude(fromNormalizedWorldX: normalizedX)
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: normalizedY)
        let phi = Float(latitude) - (.pi * 0.5)
        let theta = Float(longitude + Double.pi)
        return simd_normalize(SIMD3<Float>(sin(phi) * sin(theta),
                                           cos(phi),
                                           sin(phi) * cos(theta)))
    }

    private static func color(forHeight height: Float) -> SIMD4<Float> {
        let normalized = min(max(height * 0.05, 0), 1)
        return SIMD4<Float>(0.20 + normalized * 0.35,
                            0.45 + normalized * 0.30,
                            0.24 + normalized * 0.20,
                            1.0)
    }
}

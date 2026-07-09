// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd


class SphereGeometry {
    struct Vertex {
        var uv: SIMD2<Float>
    }
    
    struct Grid {
        var vertices: [Vertex]
        var indices: [UInt32]
    }

    static func createGrid(stacks: Int, slices: Int) -> Grid {
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        
        let uRange: (Float, Float) = (0.0, 1.0)
        let vRange: (Float, Float) = (0.0, 1.0)
        
        let uMin = uRange.0
        let uMax = uRange.1
        let vMin = vRange.0
        let vMax = vRange.1
        
        // Generate vertices and UVs
        for stack in 0...stacks {
            let t = Float(stack) / Float(stacks)
            let v = vMin + (vMax - vMin) * t
            for slice in 0...slices {
                let s = Float(slice) / Float(slices)
                let u = uMin + (uMax - uMin) * s
                vertices.append(Vertex(uv: SIMD2<Float>(u, v)))
            }
        }
        
        // Generate indices for triangles
        for stack in 0..<stacks {
            for slice in 0..<slices {
                let topLeft = stack * (slices + 1) + slice
                let topRight = topLeft + 1
                let bottomLeft = (stack + 1) * (slices + 1) + slice
                let bottomRight = bottomLeft + 1
                
                // First triangle
                indices.append(UInt32(topLeft))
                indices.append(UInt32(bottomLeft))
                indices.append(UInt32(topRight))
                
                // Second triangle
                indices.append(UInt32(topRight))
                indices.append(UInt32(bottomLeft))
                indices.append(UInt32(bottomRight))
            }
        }
        
        return Grid(vertices: vertices, indices: indices)
    }
}

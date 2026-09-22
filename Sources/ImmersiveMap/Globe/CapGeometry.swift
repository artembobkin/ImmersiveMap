// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

class CapGeometry {
    static let boundaryOverlapRadians: Float = 0.005

    struct Vertex {
        var latLon: SIMD2<Float>
    }
    
    struct Grid {
        var vertices: [Vertex]
        var indices: [UInt32]
    }
    
    static func createCapGrid(stacks: Int, slices: Int, isNorth: Bool, maxLatitude: Float) -> Grid {
        var vertices: [Vertex] = []
        var indices: [UInt32] = []

        let northStart = max(maxLatitude - boundaryOverlapRadians, 0)
        let southEnd = min(-maxLatitude + boundaryOverlapRadians, 0)

        let latStart: Float = isNorth ? northStart : -Float.pi / 2.0
        let latEnd: Float = isNorth ? Float.pi / 2.0 : southEnd
        
        for stack in 0...stacks {
            let t = Float(stack) / Float(stacks)
            let lat = latStart + (latEnd - latStart) * t
            for slice in 0...slices {
                let s = Float(slice) / Float(slices)
                let lon = s * Float.pi * 2.0
                vertices.append(Vertex(latLon: SIMD2<Float>(lat, lon)))
            }
        }
        
        // Both caps read counter-clockwise from outside the sphere with this
        // triangle order (pinned by GlobeCapOffscreenRenderTests, one
        // pole each), so the caps cull back faces the way the tile mesh does
        // and the far half of the polar fan is never rasterized. Nothing
        // writes surface depth on the sphere, so without the cull the back
        // of the fan would draw through the planet.
        for stack in 0..<stacks {
            for slice in 0..<slices {
                let topLeft = stack * (slices + 1) + slice
                let topRight = topLeft + 1
                let bottomLeft = (stack + 1) * (slices + 1) + slice
                let bottomRight = bottomLeft + 1

                indices.append(contentsOf: [UInt32(topLeft), UInt32(topRight), UInt32(bottomLeft),
                                            UInt32(bottomLeft), UInt32(topRight), UInt32(bottomRight)])
            }
        }

        return Grid(vertices: vertices, indices: indices)
    }
}

// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import simd

struct Frustum {
    var planes: [SIMD4<Float>]

    init(pv: matrix_float4x4) {
        // Extract planes using Gribb-Hartmann adjusted for Metal (0 to 1 depth buffer)
        // planes order: left, right, bottom, top, near, far
        let m0x = pv.columns.0.x
        let m0y = pv.columns.0.y
        let m0z = pv.columns.0.z
        let m0w = pv.columns.0.w
        let m1x = pv.columns.1.x
        let m1y = pv.columns.1.y
        let m1z = pv.columns.1.z
        let m1w = pv.columns.1.w
        let m2x = pv.columns.2.x
        let m2y = pv.columns.2.y
        let m2z = pv.columns.2.z
        let m2w = pv.columns.2.w
        let m3x = pv.columns.3.x
        let m3y = pv.columns.3.y
        let m3z = pv.columns.3.z
        let m3w = pv.columns.3.w

        var p: SIMD4<Float>

        p = SIMD4<Float>(m0w + m0x, m1w + m1x, m2w + m2x, m3w + m3x)
        p /= length(SIMD3<Float>(p.x, p.y, p.z))
        planes = [p]

        p = SIMD4<Float>(m0w - m0x, m1w - m1x, m2w - m2x, m3w - m3x)
        p /= length(SIMD3<Float>(p.x, p.y, p.z))
        planes.append(p)

        p = SIMD4<Float>(m0w + m0y, m1w + m1y, m2w + m2y, m3w + m3y)
        p /= length(SIMD3<Float>(p.x, p.y, p.z))
        planes.append(p)

        p = SIMD4<Float>(m0w - m0y, m1w - m1y, m2w - m2y, m3w - m3y)
        p /= length(SIMD3<Float>(p.x, p.y, p.z))
        planes.append(p)

        p = SIMD4<Float>(m0z, m1z, m2z, m3z)
        p /= length(SIMD3<Float>(p.x, p.y, p.z))
        planes.append(p)

        p = SIMD4<Float>(m0w - m0z, m1w - m1z, m2w - m2z, m3w - m3z)
        p /= length(SIMD3<Float>(p.x, p.y, p.z))
        planes.append(p)
    }

    func isBoxVisible(min: SIMD4<Float>, max: SIMD4<Float>) -> Bool {
        for plane in planes {
            let px = plane.x >= 0 ? max.x : min.x
            let py = plane.y >= 0 ? max.y : min.y
            let pz = plane.z >= 0 ? max.z : min.z
            let dist = plane.x * px + plane.y * py + plane.z * pz + plane.w
            if dist < 0 {
                return false
            }
        }
        return true
    }

    func isSphereVisible(center: SIMD3<Float>,
                         radius: Float) -> Bool {
        for plane in planes {
            let distance = (plane.x * center.x) + (plane.y * center.y) + (plane.z * center.z) + plane.w
            if distance < -radius {
                return false
            }
        }
        return true
    }

    func containsSphere(center: SIMD3<Float>,
                        radius: Float) -> Bool {
        for plane in planes {
            let distance = (plane.x * center.x) + (plane.y * center.y) + (plane.z * center.z) + plane.w
            if distance < radius {
                return false
            }
        }
        return true
    }
}

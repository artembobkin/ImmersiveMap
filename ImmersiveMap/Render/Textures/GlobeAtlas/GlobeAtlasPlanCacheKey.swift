// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import simd

struct GlobeAtlasPlanCacheKey: Hashable {
    private let renderSurfaceMode: UInt8
    private let placementVersion: UInt64
    private let drawWidth: UInt64
    private let drawHeight: UInt64
    private let cameraMatrix: MatrixBits
    private let cameraEye: Float3Bits
    private let globe: GlobeUniformBits
    private let textureSize: Int
    private let qualityScale: UInt32

    init(renderSurfaceMode: ViewMode,
         placementVersion: UInt64,
         drawSize: CGSize,
         cameraUniform: CameraUniform,
         globe: GlobeUniform,
         textureSize: Int,
         qualityScale: Float) {
        self.renderSurfaceMode = Self.renderSurfaceModeCode(renderSurfaceMode)
        self.placementVersion = placementVersion
        self.drawWidth = Double(drawSize.width).bitPattern
        self.drawHeight = Double(drawSize.height).bitPattern
        self.cameraMatrix = MatrixBits(cameraUniform.matrix)
        self.cameraEye = Float3Bits(cameraUniform.eye)
        self.globe = GlobeUniformBits(globe)
        self.textureSize = textureSize
        self.qualityScale = qualityScale.bitPattern
    }

    private static func renderSurfaceModeCode(_ renderSurfaceMode: ViewMode) -> UInt8 {
        switch renderSurfaceMode {
        case .spherical:
            return 0
        case .flat:
            return 1
        }
    }
}

private struct MatrixBits: Hashable {
    private let m00: UInt32
    private let m01: UInt32
    private let m02: UInt32
    private let m03: UInt32
    private let m10: UInt32
    private let m11: UInt32
    private let m12: UInt32
    private let m13: UInt32
    private let m20: UInt32
    private let m21: UInt32
    private let m22: UInt32
    private let m23: UInt32
    private let m30: UInt32
    private let m31: UInt32
    private let m32: UInt32
    private let m33: UInt32

    init(_ matrix: matrix_float4x4) {
        m00 = matrix.columns.0.x.bitPattern
        m01 = matrix.columns.0.y.bitPattern
        m02 = matrix.columns.0.z.bitPattern
        m03 = matrix.columns.0.w.bitPattern
        m10 = matrix.columns.1.x.bitPattern
        m11 = matrix.columns.1.y.bitPattern
        m12 = matrix.columns.1.z.bitPattern
        m13 = matrix.columns.1.w.bitPattern
        m20 = matrix.columns.2.x.bitPattern
        m21 = matrix.columns.2.y.bitPattern
        m22 = matrix.columns.2.z.bitPattern
        m23 = matrix.columns.2.w.bitPattern
        m30 = matrix.columns.3.x.bitPattern
        m31 = matrix.columns.3.y.bitPattern
        m32 = matrix.columns.3.z.bitPattern
        m33 = matrix.columns.3.w.bitPattern
    }
}

private struct Float3Bits: Hashable {
    private let x: UInt32
    private let y: UInt32
    private let z: UInt32

    init(_ value: SIMD3<Float>) {
        x = value.x.bitPattern
        y = value.y.bitPattern
        z = value.z.bitPattern
    }
}

private struct GlobeUniformBits: Hashable {
    private let panX: UInt32
    private let panY: UInt32
    private let radius: UInt32
    private let transition: UInt32

    init(_ globe: GlobeUniform) {
        panX = globe.panX.bitPattern
        panY = globe.panY.bitPattern
        radius = globe.radius.bitPattern
        transition = globe.transition.bitPattern
    }
}

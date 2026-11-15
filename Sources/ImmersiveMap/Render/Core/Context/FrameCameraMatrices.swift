// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  FrameCameraMatrices.swift
//  ImmersiveMap
//

import simd

struct FrameCameraMatrices {
    let projectionView: matrix_float4x4
    let view: matrix_float4x4
    let screen: matrix_float4x4

    static let identity = FrameCameraMatrices(projectionView: matrix_identity_float4x4,
                                              view: matrix_identity_float4x4,
                                              screen: matrix_identity_float4x4)
}

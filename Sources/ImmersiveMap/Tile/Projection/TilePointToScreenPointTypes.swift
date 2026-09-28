// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TilePointToScreenPointTypes.swift
//  ImmersiveMap
//

import Foundation
import simd

struct TilePointInput {
    var uv: SIMD2<Float>
    var tile: SIMD3<Int32>
    var tileSlotIndex: UInt32 = 0
    /// The roof the point stands on in tile units (a 4096 extent), the
    /// extrusion mesh's height scale. Zero on the ground. The flat
    /// projection lifts the point by it where the frame draws buildings.
    /// It sits in what was padding, so the stride stays the GPU mirror's.
    var roofHeight: Float = 0
}

struct ScreenParams {
    var viewportSize: SIMD2<Float>
    var outputPixels: UInt32
    var _padding: UInt32 = 0
}

struct ScreenPointOutput {
    var position: SIMD2<Float>
    var depth: Float
    var visible: UInt32
    var visibilityAlpha: Float

    init(position: SIMD2<Float>,
         depth: Float,
         visible: UInt32,
         visibilityAlpha: Float? = nil) {
        self.position = position
        self.depth = depth
        self.visible = visible
        self.visibilityAlpha = visibilityAlpha ?? (visible != 0 ? 1.0 : 0.0)
    }
}

struct TilePointToScreenPointSnapshot {
    static let empty = TilePointToScreenPointSnapshot(pointInputs: [],
                                                      tileSlotVisibleTileIndices: [])

    let pointInputs: [TilePointInput]
    let tileSlotVisibleTileIndices: [UInt32]

    var pointsCount: Int {
        pointInputs.count
    }
}

struct TilePointScreenProjectionResult {
    static let empty = TilePointScreenProjectionResult(screenPoints: [],
                                                       horizonVisibility: [])

    var screenPoints: [ScreenPointOutput]
    var horizonVisibility: [Bool]
}

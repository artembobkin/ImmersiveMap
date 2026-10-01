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
    /// The roof over the point in tile units (a 4096 extent), the
    /// extrusion mesh's height scale. Zero on open ground. The flat
    /// projection tests the point for view at the roof, and draws it there
    /// too when `liftsToRoof` is set.
    var roofHeight: Float = 0
    /// 1 when the point draws on the roof over it (a label naming the
    /// building itself), 0 when it draws on the ground (a label of
    /// something inside the building). In the padding after the roof.
    var liftsToRoof: UInt32 = 0
    /// 1 when the roof over the point is a building a landmark model
    /// stands in for: the flat projection takes the drawn model's top
    /// where it covers the point. The last of the padding.
    var roofIsReplaced: UInt32 = 0
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

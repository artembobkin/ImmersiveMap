// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  FrameContextSharedState.swift
//  ImmersiveMap
//

import Metal

struct NightLightsAtlasEntry: Equatable {
    let tile: Tile
    let pageIndex: Int
    let uvOrigin: SIMD2<Float>
    let uvScale: SIMD2<Float>
}

struct NightLightsAtlasState {
    static let empty = NightLightsAtlasState(pages: [], entries: [])

    var pages: [MTLTexture]
    var entries: [NightLightsAtlasEntry]
}

struct NightLightsAtlasSurfaceBinding {
    static let maxPageCount = 8
    static let maxEntryCount = 128

    let pages: [MTLTexture]
    let entryUniforms: [NightLightsAtlasEntryUniform]

    init(state: NightLightsAtlasState) {
        self.pages = Array(state.pages.prefix(Self.maxPageCount))
        self.entryUniforms = state.entries
            .lazy
            .filter { entry in
                entry.pageIndex < Self.maxPageCount
            }
            .prefix(Self.maxEntryCount)
            .map { entry in
                NightLightsAtlasEntryUniform(tile: SIMD3<Int32>(Int32(entry.tile.x),
                                                                Int32(entry.tile.y),
                                                                Int32(entry.tile.z)),
                                             pageIndex: Int32(entry.pageIndex),
                                             uvOrigin: entry.uvOrigin,
                                             uvScale: entry.uvScale)
            }
    }
}

struct NightLightsAtlasEntryUniform {
    var tileAndPage: SIMD4<Int32>
    var uvOriginAndScale: SIMD4<Float>

    var tile: SIMD3<Int32> {
        get { SIMD3<Int32>(tileAndPage.x, tileAndPage.y, tileAndPage.z) }
        set {
            tileAndPage.x = newValue.x
            tileAndPage.y = newValue.y
            tileAndPage.z = newValue.z
        }
    }

    var pageIndex: Int32 {
        get { tileAndPage.w }
        set { tileAndPage.w = newValue }
    }

    var uvOrigin: SIMD2<Float> {
        get { SIMD2<Float>(uvOriginAndScale.x, uvOriginAndScale.y) }
        set {
            uvOriginAndScale.x = newValue.x
            uvOriginAndScale.y = newValue.y
        }
    }

    var uvScale: SIMD2<Float> {
        get { SIMD2<Float>(uvOriginAndScale.z, uvOriginAndScale.w) }
        set {
            uvOriginAndScale.z = newValue.x
            uvOriginAndScale.w = newValue.y
        }
    }

    init(tile: SIMD3<Int32>, pageIndex: Int32, uvOrigin: SIMD2<Float>, uvScale: SIMD2<Float>) {
        self.tileAndPage = SIMD4<Int32>(tile.x, tile.y, tile.z, pageIndex)
        self.uvOriginAndScale = SIMD4<Float>(uvOrigin.x, uvOrigin.y, uvScale.x, uvScale.y)
    }
}

struct BaseLabelState {
    static let empty = BaseLabelState(labelInputsCount: 0,
                                      activeLabelSpanCount: 0,
                                      labelRuntimeMetaBuffer: nil,
                                      screenPositionsBuffer: nil,
                                      baseLabelsDrawBatches: [],
                                      hasActiveFadeAnimations: false,
                                      hasActiveVisibilityCycle: false)

    var labelInputsCount: Int
    var activeLabelSpanCount: Int
    var labelRuntimeMetaBuffer: MTLBuffer?
    var screenPositionsBuffer: MTLBuffer?
    var baseLabelsDrawBatches: [BaseLabelDrawBatch]
    var hasActiveFadeAnimations: Bool
    var hasActiveVisibilityCycle: Bool
}

struct RoadLabelState {
    static let empty = RoadLabelState(instanceCount: 0,
                                      glyphCount: 0,
                                      activeRoadLabelTiles: [],
                                      runtimeMetaBuffer: nil,
                                      placementBuffer: nil,
                                      glyphInputBuffer: nil,
                                      glyphVerticesBuffer: nil,
                                      glyphVertexCount: 0,
                                      drawLabels: [],
                                      hasActiveFadeAnimations: false)

    var instanceCount: Int
    var glyphCount: Int
    var activeRoadLabelTiles: [VisibleTile]
    var runtimeMetaBuffer: MTLBuffer?
    var placementBuffer: MTLBuffer?
    var glyphInputBuffer: MTLBuffer?
    var glyphVerticesBuffer: MTLBuffer?
    var glyphVertexCount: Int
    var drawLabels: [DrawRoadLabels]
    var hasActiveFadeAnimations: Bool
}

struct AvatarState {
    static let empty = AvatarState(hasActiveAnimations: false,
                                   selectionSnapshot: .empty)

    var hasActiveAnimations: Bool
    var selectionSnapshot: AvatarSelectionSnapshot
}

final class FrameContextSharedState {
    var tilePlacementState: TilePlacementState = .empty
    var placeTileTrackingState: PlaceTileTrackingState = .empty
    var tileProjectionIndexState: TileProjectionIndexState = .empty
    var nightLightsAtlasState: NightLightsAtlasState = .empty
    var globeAtlasDebugSummary: GlobeAtlasDebugSummary?
    var baseLabelState: BaseLabelState = .empty
    var roadLabelState: RoadLabelState = .empty
    var avatarState: AvatarState = .empty
}

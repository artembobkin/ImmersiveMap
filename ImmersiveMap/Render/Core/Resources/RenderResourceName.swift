// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RenderResourceName.swift
//  ImmersiveMap
//

import Foundation

enum RenderResourceName: String {
    case tileVertexBuffer = "TileVertexBuffer"
    case tileStyleBuffer = "TileStyleBuffer"
    case labelGlyphAtlas = "LabelGlyphAtlas"
    case poiSpriteAtlas = "PoiSpriteAtlas"
    case baseLabelRuntimeBuffer = "BaseLabelRuntimeBuffer"
    case roadLabelRuntimeBuffer = "RoadLabelRuntimeBuffer"
    case colorTexture = "ColorTexture"
    case postProcessingInputTexture = "PostProcessingInputTexture"
    case overlayDepthTexture = "OverlayDepthTexture"
    case depthTexture = "DepthTexture"
    case buildingWinnerIDTexture = "BuildingWinnerIDTexture"
    case buildingWinnerDepthTexture = "BuildingWinnerDepthTexture"
    case tileOriginDataBuffer = "TileOriginDataBuffer"
    case polygonPipeline = "PolygonPipeline"
    case tilePipeline = "TilePipeline"
    case extrudedTilePipeline = "ExtrudedTilePipeline"
    case extrudedTileWinnerPipeline = "ExtrudedTileWinnerPipeline"
    case globePipeline = "GlobePipeline"
    case terrainPipeline = "TerrainPipeline"
}

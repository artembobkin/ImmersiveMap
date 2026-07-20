// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

struct DebugOverlayCoordinateLines: Equatable {
    let zoom: String
    let latLon: String
}

struct DebugOverlayHUDSnapshot: Equatable {
    let coordinateLines: DebugOverlayCoordinateLines
    let diagnosticsLines: [String]
    let atlasPages: [TileAtlasDebugPage]
    let tileLoadingStatusLines: [String]
    let tileLoadingStatusTiles: [TileLoadingStatusTileSnapshot]
    let coordinateScale: Float
    let diagnosticsScale: Float
    let leftPadding: Float
    let topPadding: Float
    let sectionSpacing: Float
    let textColor: SIMD3<Float>

    static func make(settings: ImmersiveMapSettings.DebugSettings,
                     zoom: Double,
                     latitude: Double,
                     longitude: Double,
                     cameraDebugLines: [String],
                     diagnostics: FrameDiagnostics?,
                     atlasDebugSummary: TileAtlasDebugSummary? = nil,
                     tileLoadingStatus: TileLoadingStatusSnapshot? = nil) -> DebugOverlayHUDSnapshot? {
        guard settings.enableDebugPanel else {
            return nil
        }

        let coordinateLines = DebugOverlayRenderer.makeCoordinateTextLines(zoom: zoom,
                                                                           latitude: latitude,
                                                                           longitude: longitude)
        return DebugOverlayHUDSnapshot(
            coordinateLines: DebugOverlayCoordinateLines(zoom: coordinateLines.zoom,
                                                        latLon: coordinateLines.latLon),
            diagnosticsLines: DebugOverlayRenderer.makeOverlayDiagnosticsTextLines(cameraDebugLines: cameraDebugLines,
                                                                                  diagnostics: diagnostics),
            atlasPages: atlasDebugSummary?.pages ?? [],
            tileLoadingStatusLines: tileLoadingStatus?.lines ?? [],
            tileLoadingStatusTiles: tileLoadingStatus?.tiles ?? [],
            coordinateScale: settings.coordinateScale,
            diagnosticsScale: settings.diagnosticsScale,
            leftPadding: settings.leftPadding,
            topPadding: settings.topPadding,
            sectionSpacing: settings.sectionSpacing,
            textColor: settings.textColor
        )
    }

    static func make(settings: ImmersiveMapSettings.DebugSettings,
                     frameContext: FrameContext,
                     diagnostics: FrameDiagnostics?,
                     tileLoadingStatus: TileLoadingStatusSnapshot? = nil) -> DebugOverlayHUDSnapshot? {
        let cameraPosition = frameContext.mapCameraState.cameraPosition()
        return make(settings: settings,
                    zoom: frameContext.mapCameraState.zoom,
                    latitude: cameraPosition.latitudeDegrees,
                    longitude: cameraPosition.longitudeDegrees,
                    cameraDebugLines: makeCameraDebugLines(frameContext: frameContext),
                    diagnostics: diagnostics,
                    atlasDebugSummary: frameContext.sharedState.tileAtlasDebugSummary,
                    tileLoadingStatus: tileLoadingStatus)
    }

    private static func makeCameraDebugLines(frameContext: FrameContext) -> [String] {
        let cameraState = frameContext.mapCameraState
        let pitchDegrees = Double(cameraState.pitch) * 180.0 / Double.pi
        let bearingDegrees = Double(cameraState.bearing) * 180.0 / Double.pi
        let surface = frameContext.renderSurfaceMode == .spherical ? "globe" : "flat"
        let viewport = frameContext.viewport
        let eye = frameContext.cameraEye
        let placeTiles = frameContext.sharedState.placeTileTrackingState.placeTiles
        let sourceZoomCounts = zoomCountsLine(title: "srcZ", tiles: placeTiles.map { $0.metalTile.tile })
        let targetZoomCounts = zoomCountsLine(title: "targetZ", tiles: placeTiles.map { $0.placeIn.tile })

        return [
            "camera z:\(format(cameraState.zoom)) pitch:\(format(pitchDegrees)) bearing:\(format(bearingDegrees))",
            "surface:\(surface) transition:\(format(Double(frameContext.transition))) viewport:\(Int(viewport.x))x\(Int(viewport.y))",
            "eye x:\(format(Double(eye.x))) y:\(format(Double(eye.y))) z:\(format(Double(eye.z)))",
            targetZoomCounts,
            sourceZoomCounts
        ] + RendererDebugOverlayDrawer.makeAtlasDebugLines(summary: frameContext.sharedState.tileAtlasDebugSummary)
    }

    private static func zoomCountsLine(title: String, tiles: [Tile]) -> String {
        let counts = Dictionary(grouping: tiles, by: \.z)
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
            .map { "z\($0.key):\($0.value)" }
            .joined(separator: " ")
        return "\(title): \(counts.isEmpty ? "none" : counts)"
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}

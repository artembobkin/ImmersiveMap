// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

struct DebugOverlayCoordinateLines: Equatable {
    let zoom: String
    let latLon: String
}

/// What the debug panel shows right now, so a frame builds only that: the
/// panel is in step with every rendered frame, one to one, and the frame
/// pays for one tab's data, not the whole panel's.
struct DebugOverlayHUDContentRequest: OptionSet, Sendable, Equatable {
    let rawValue: UInt8

    /// The camera's lines and the frame's diagnostics.
    static let stats = DebugOverlayHUDContentRequest(rawValue: 1 << 0)
    /// The loader's status, the tile cards and the coverage map.
    static let tiles = DebugOverlayHUDContentRequest(rawValue: 1 << 1)
    /// The terrain store's status, the terrain cards and their map.
    static let relief = DebugOverlayHUDContentRequest(rawValue: 1 << 2)
    static let all: DebugOverlayHUDContentRequest = [.stats, .tiles, .relief]
}

struct DebugOverlayHUDSnapshot: Equatable {
    let coordinateLines: DebugOverlayCoordinateLines
    let diagnosticsLines: [String]
    let tileLoadingStatusLines: [String]
    let tileLoadingStatusTiles: [TileLoadingStatusTileSnapshot]
    let coordinateScale: Float
    let diagnosticsScale: Float
    let leftPadding: Float
    let topPadding: Float
    let sectionSpacing: Float
    let textColor: SIMD3<Float>
    /// The planning zoom as a number (`FrameContext.planningZoom`), for the
    /// controls that read a value off a zoom curve (the ground fog group),
    /// which the frame reads at that zoom.
    var cameraZoom: Double = 0
    /// The camera's own zoom as a number, for the zoom badge
    /// (`DebugOverlayZoomBadge`), which shows it beside `cameraZoom`.
    var zoom: Double = 0
    /// The compass direction the camera looks in, in degrees clockwise
    /// from north (`DebugOverlaySunDial.viewAzimuthDegrees`): the sun
    /// picker turns with it.
    var viewAzimuthDegrees: Double = 0
    /// The frame's tile coverage from above, for the panel's coverage map.
    var tileCoverage: DebugOverlayTileCoverage? = nil
    /// The terrain store's status (`GroundReliefStatusSnapshot`), nil with
    /// the relief off or its tab not shown.
    var reliefStatus: GroundReliefStatusSnapshot? = nil
    /// The terrain from above, for the relief tab's map.
    var reliefCoverage: DebugOverlayReliefCoverage? = nil

    /// The same frame snapshot with the tile list read again from the
    /// reporter: what the panel applies between frames.
    func replacingTileLoadingStatus(_ tileLoadingStatus: TileLoadingStatusSnapshot?) -> DebugOverlayHUDSnapshot {
        DebugOverlayHUDSnapshot(coordinateLines: coordinateLines,
                                diagnosticsLines: diagnosticsLines,
                                tileLoadingStatusLines: tileLoadingStatus?.lines ?? [],
                                tileLoadingStatusTiles: tileLoadingStatus?.tiles ?? [],
                                coordinateScale: coordinateScale,
                                diagnosticsScale: diagnosticsScale,
                                leftPadding: leftPadding,
                                topPadding: topPadding,
                                sectionSpacing: sectionSpacing,
                                textColor: textColor,
                                cameraZoom: cameraZoom,
                                zoom: self.zoom,
                                viewAzimuthDegrees: viewAzimuthDegrees,
                                tileCoverage: tileCoverage,
                                reliefStatus: reliefStatus,
                                reliefCoverage: reliefCoverage)
    }

    static func make(settings: ImmersiveMapSettings.DebugSettings,
                     zoom: Double,
                     planningZoom: Double? = nil,
                     viewAzimuthDegrees: Double = 0,
                     latitude: Double,
                     longitude: Double,
                     cameraDebugLines: [String],
                     diagnostics: FrameDiagnostics?,
                     tileLoadingStatus: TileLoadingStatusSnapshot? = nil,
                     tileCoverage: DebugOverlayTileCoverage? = nil,
                     reliefStatus: GroundReliefStatusSnapshot? = nil,
                     reliefCoverage: DebugOverlayReliefCoverage? = nil,
                     content: DebugOverlayHUDContentRequest = .all) -> DebugOverlayHUDSnapshot? {
        guard settings.enableDebugPanel else {
            return nil
        }

        let coordinateLines = DebugOverlayRenderer.makeCoordinateTextLines(zoom: zoom,
                                                                           latitude: latitude,
                                                                           longitude: longitude)
        let tileLoadingStatus = content.contains(.tiles) ? tileLoadingStatus : nil
        return DebugOverlayHUDSnapshot(
            coordinateLines: DebugOverlayCoordinateLines(zoom: coordinateLines.zoom,
                                                        latLon: coordinateLines.latLon),
            diagnosticsLines: content.contains(.stats)
                ? DebugOverlayRenderer.makeOverlayDiagnosticsTextLines(cameraDebugLines: cameraDebugLines,
                                                                       diagnostics: diagnostics)
                : [],
            tileLoadingStatusLines: tileLoadingStatus?.lines ?? [],
            tileLoadingStatusTiles: tileLoadingStatus?.tiles ?? [],
            coordinateScale: settings.coordinateScale,
            diagnosticsScale: settings.diagnosticsScale,
            leftPadding: settings.leftPadding,
            topPadding: settings.topPadding,
            sectionSpacing: settings.sectionSpacing,
            textColor: settings.textColor,
            cameraZoom: planningZoom ?? zoom,
            zoom: zoom,
            viewAzimuthDegrees: viewAzimuthDegrees,
            tileCoverage: content.contains(.tiles) ? tileCoverage : nil,
            reliefStatus: content.contains(.relief) ? reliefStatus : nil,
            reliefCoverage: content.contains(.relief) ? reliefCoverage : nil
        )
    }

    /// The frame's snapshot for the panel's `content`: the rest is left
    /// empty and never built.
    static func make(settings: ImmersiveMapSettings.DebugSettings,
                     frameContext: FrameContext,
                     diagnostics: FrameDiagnostics?,
                     tileLoadingStatus: TileLoadingStatusSnapshot? = nil,
                     content: DebugOverlayHUDContentRequest = .all) -> DebugOverlayHUDSnapshot? {
        let cameraPosition = frameContext.mapCameraState.cameraPosition()
        var reliefStatus = content.contains(.relief) ? frameContext.services.groundRelief?.statusSnapshot() : nil
        reliefStatus?.surroundings = frameContext.terrainSurroundings
        let viewCoverage = content.contains(.tiles) || reliefStatus != nil
            ? DebugOverlayTileCoverage.make(frameContext: frameContext) : nil
        return make(settings: settings,
                    zoom: frameContext.mapCameraState.zoom,
                    planningZoom: frameContext.planningZoom,
                    viewAzimuthDegrees: DebugOverlaySunDial.viewAzimuthDegrees(bearingRadians: Double(frameContext.mapCameraState.bearing)),
                    latitude: cameraPosition.latitudeDegrees,
                    longitude: cameraPosition.longitudeDegrees,
                    cameraDebugLines: content.contains(.stats) ? makeCameraDebugLines(frameContext: frameContext) : [],
                    diagnostics: diagnostics,
                    tileLoadingStatus: tileLoadingStatus,
                    tileCoverage: content.contains(.tiles) ? viewCoverage : nil,
                    reliefStatus: reliefStatus,
                    reliefCoverage: reliefStatus.flatMap { status in
                        viewCoverage.map { DebugOverlayReliefCoverage.make(status: status, view: $0) }
                    },
                    content: content)
    }

    private static func makeCameraDebugLines(frameContext: FrameContext) -> [String] {
        let cameraState = frameContext.mapCameraState
        let pitchDegrees = Double(cameraState.pitch) * 180.0 / Double.pi
        let bearingDegrees = Double(cameraState.bearing) * 180.0 / Double.pi
        let surface = frameContext.renderSurfaceMode == .spherical ? "globe" : "flat"
        let viewport = frameContext.viewport
        let eye = frameContext.cameraEye
        let placeTiles = frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements
        let sourceZoomCounts = zoomCountsLine(title: "srcZ", tiles: placeTiles.map { $0.metalTile.tile })
        let targetZoomCounts = zoomCountsLine(title: "targetZ", tiles: placeTiles.map { $0.placeIn.tile })

        // One value a line, so a reader finds the one they watch.
        var lines = [
            "camera z:\(format(cameraState.zoom))",
            "planning z:\(format(frameContext.planningZoom))",
            "animated z:\(format(frameContext.animatedZoom))",
            "pitch:\(format(pitchDegrees))",
            "bearing:\(format(bearingDegrees))",
            "surface:\(surface)",
            "transition:\(format(Double(frameContext.transition)))",
            "viewport:\(Int(viewport.x))x\(Int(viewport.y))",
            "eye x:\(format(Double(eye.x)))",
            "eye y:\(format(Double(eye.y)))",
            "eye z:\(format(Double(eye.z)))"
        ]
        lines += reliefLines(frameContext: frameContext)
        if let report = frameContext.terrainFollowReport, frameContext.renderSurfaceMode == .flat {
            lines += ["follow:\(report.path.rawValue)",
                      "arm:\(format(report.armMetres))m",
                      "clear:\(format(report.clearedZoomDelta))"]
        }
        lines += [
            ringRulesLine(frameContext.visibleContent.flatRingBands),
            targetZoomCounts,
            sourceZoomCounts
        ]
        return lines
    }

    /// The ground relief under the camera: the terrain under the point it
    /// looks at, the datum the relief is drawn from, and the eye's own
    /// altitude over the sea in the terrain's metres as drawn, which a pan
    /// over the relief keeps (`CameraTerrainFollow`). Empty without a
    /// relief or off the flat map.
    private static func reliefLines(frameContext: FrameContext) -> [String] {
        guard let relief = frameContext.services.groundRelief,
              frameContext.renderSurfaceMode == .flat else {
            return []
        }
        let centre = frameContext.mapCameraState.centerWorldMercator
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: centre.y)
        let unitsPerMetre = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitude,
                                                                      renderMapSize: frameContext.flatRenderState.renderMapSize)
        let eyeHeightMetres = Double(frameContext.cameraEye.z) / unitsPerMetre
        let state = relief.isActive ? "on" : "off"
        let terrainZoom = relief.terrainZoom(forTargetZoom: frameContext.visibleContent.tileZoomLevel)
        let strength = relief.strength(atNormalizedWorld: centre, terrainZoom: terrainZoom).map { Double($0) }
        return ["relief:\(state)",
                "datum:\(format(Double(relief.datumMetres)))m",
                "eye alt:\(format(Double(relief.datumMetres) + eyeHeightMetres))m",
                "eye height:\(format(eyeHeightMetres))m",
                "strength:x\(strength.map(format) ?? "-")"]
    }

    /// The ring rules as the frame resolved them on either surface,
    /// nearest first: each band's zoom, last ring and tile count. "rules:
    /// none" for a frame with no coverage.
    static func ringRulesLine(_ bands: [FlatRingBand]) -> String {
        guard bands.isEmpty == false else { return "rules: none" }
        let entries = bands.map { band in
            "z\(band.zoom) \u{2264}\(band.distance) (\(band.tileCount))"
        }
        return "rules: " + entries.joined(separator: " / ")
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

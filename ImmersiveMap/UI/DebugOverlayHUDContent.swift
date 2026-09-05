// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Platform-neutral construction of debug HUD texts.
/// UIKit and AppKit views use the same strings; the controls themselves are platform-specific.
enum DebugOverlayHUDTextComposer {
    static func tilesStatusText(lines: [String]) -> String {
        guard lines.isEmpty == false else {
            return "tiles: idle"
        }
        return lines.joined(separator: "\n")
    }

    /// Summary of the tile list: how many are currently tracked in total. Drawn
    /// by the platform views in a highlight color, separately from the white status.
    static func tilesTotalText(count: Int) -> String {
        "tiles total: \(count)"
    }

    /// The last line of a tile list that ran out of slots. The list reserves a
    /// fixed height so nothing under it moves, so the rows it cannot show are
    /// counted rather than dropped in silence.
    static func tilesOverflowText(count: Int) -> String {
        "+\(count) more"
    }

    /// Titles of the tile grid density picker, in `DebugTileGridDensity.options` order.
    static let tileGridDensityTitles: [String] = DebugTileGridDensity.options.map { "\($0)x\($0)" }

    static func tileGridDensityIndex(for density: Int) -> Int {
        DebugTileGridDensity.options.firstIndex(of: DebugTileGridDensity.clamp(density)) ?? 0
    }

    static func tileGridDensity(atIndex index: Int) -> Int {
        guard index >= 0, index < DebugTileGridDensity.options.count else {
            return DebugTileGridDensity.standard
        }
        return DebugTileGridDensity.options[index]
    }

    static func traceButtonTitle(isRecording: Bool) -> String {
        isRecording ? "Stop recording" : "Start recording"
    }

    static func traceButtonImageName(isRecording: Bool) -> String {
        isRecording ? "stop.circle" : "record.circle"
    }

    static func tileTraceStatusText(_ snapshot: TileTraceRecorderSnapshot) -> String {
        guard let fileURL = snapshot.fileURL else {
            return "Trace recording is off"
        }

        let prefix = snapshot.isRecording ? "Recording" : "Last trace"
        return "\(prefix): \(fileURL.path)"
    }

    static func baseLabelTraceStatusText(_ snapshot: BaseLabelTraceRecorderSnapshot) -> String {
        guard let fileURL = snapshot.fileURL else {
            return "Base label trace recording is off"
        }

        let prefix = snapshot.isRecording ? "Recording" : "Last trace"
        return "\(prefix): \(fileURL.path)"
    }
}

/// Row of the debug HUD tile status list; a shared model for the platform list views.
enum DebugOverlayTilesStatusRow: Equatable {
    case tile(TileLoadingStatusTileSnapshot, isExpanded: Bool, canExpand: Bool)
    case stage(tile: Tile, stage: TilePreparationStageSnapshot, isExpanded: Bool)
    case layer(tile: Tile, timing: TileParseLayerTiming)

    var text: String {
        switch self {
        case let .tile(tile, isExpanded, canExpand):
            let disclosure = canExpand ? (isExpanded ? "▾" : "▸") : " "
            let tileText = "z\(tile.tile.z)/\(tile.tile.x)/\(tile.tile.y)"
            let detailText = tile.detail.isEmpty ? Self.statusText(tile.status) : tile.detail
            return "\(disclosure) \(tileText) \(detailText)"
        case let .stage(_, stage, isExpanded):
            let disclosure = stage.layerTimings.isEmpty ? " " : (isExpanded ? "▾" : "▸")
            if let duration = stage.duration {
                return "  \(disclosure) \(stage.name) \(Self.millisecondsDescription(duration))"
            }
            return "  \(disclosure) \(stage.name)"
        case let .layer(_, timing):
            return "    \(timing.layerName) \(Self.millisecondsDescription(timing.duration))"
        }
    }

    static func visibleRows(tiles: [TileLoadingStatusTileSnapshot],
                            expandedTiles: Set<Tile>,
                            expandedParseStageTiles: Set<Tile>) -> [DebugOverlayTilesStatusRow] {
        tiles.flatMap { tile -> [DebugOverlayTilesStatusRow] in
            let isTileExpanded = expandedTiles.contains(tile.tile)
            var rows: [DebugOverlayTilesStatusRow] = [
                .tile(tile,
                      isExpanded: isTileExpanded,
                      canExpand: tile.preparationStages.isEmpty == false)
            ]
            guard isTileExpanded else {
                return rows
            }
            for stage in tile.preparationStages {
                let isParseExpanded = stage.name == "parse" && expandedParseStageTiles.contains(tile.tile)
                rows.append(.stage(tile: tile.tile, stage: stage, isExpanded: isParseExpanded))
                if stage.name == "parse", isParseExpanded {
                    rows.append(contentsOf: stage.layerTimings.map { .layer(tile: tile.tile, timing: $0) })
                }
            }
            return rows
        }
    }

    static func statusText(_ status: TileLoadingTileStatus) -> String {
        switch status {
        case .queued:
            return "queued"
        case .loading:
            return "network"
        case .parsing:
            return "parse"
        case .ready:
            return "ready"
        case .failed:
            return "failed"
        }
    }

    static func millisecondsDescription(_ duration: TimeInterval) -> String {
        "\(Int((duration * 1000).rounded()))ms"
    }
}

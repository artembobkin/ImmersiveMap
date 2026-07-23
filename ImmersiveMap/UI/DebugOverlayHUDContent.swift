// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Платформенно-нейтральное построение текстов debug HUD.
/// UIKit и AppKit view используют одни и те же строки; сами контролы платформенные.
enum DebugOverlayHUDTextComposer {
    static func atlasDetailsText(pages: [TileAtlasDebugPage]) -> String {
        guard pages.isEmpty == false else {
            return "atlas pages: none"
        }

        let allocationCount = pages.reduce(0) { $0 + $1.allocations.count }
        let pageSummary = pages
            .map { "p\($0.pageIndex):\($0.allocations.count)" }
            .joined(separator: " ")
        let previewLines = pages.flatMap { page in
            page.allocations.prefix(4).map { allocation in
                return "p\(page.pageIndex) d\(allocation.atlasDepth.rawValue) " +
                    "src z\(allocation.sourceTile.z)/\(allocation.sourceTile.x)/\(allocation.sourceTile.y) " +
                    "dst z\(allocation.targetTile.z)/\(allocation.targetTile.x)/\(allocation.targetTile.y)" +
                    allocationStateSuffix(allocation)
            }
        }
        return (["atlas pages:\(pages.count) alloc:\(allocationCount) \(pageSummary)"] + previewLines)
            .joined(separator: "\n")
    }

    static func tilesStatusText(lines: [String]) -> String {
        guard lines.isEmpty == false else {
            return "tiles: idle"
        }
        return lines.joined(separator: "\n")
    }

    /// Итог списка тайлов: сколько их сейчас отслеживается всего. Рисуется
    /// платформенными view выделенным цветом отдельно от белого статуса.
    static func tilesTotalText(count: Int) -> String {
        "tiles total: \(count)"
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

    private static func allocationStateSuffix(_ allocation: TileAtlasDebugAllocation) -> String {
        switch allocation.lodKind {
        case .exact:
            return allocation.sourceTile == allocation.targetTile ? "" : " retained"
        case .coarseSubstitute:
            return " coarse"
        case .retainedReplacement:
            return " retained"
        }
    }
}

/// Строка списка статусов тайлов debug HUD; общая модель для платформенных list view.
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

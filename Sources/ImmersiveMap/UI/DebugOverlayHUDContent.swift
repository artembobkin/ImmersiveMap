// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
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

/// One tile of the debug HUD's tile list, as a card: everything the list
/// knows of the tile at a glance, with no row to open. A shared model for
/// the platform views, which only draw it (`DebugOverlayTileCardLayout`
/// says where).
struct DebugOverlayTileCard: Equatable {
    let tile: Tile
    let status: TileLoadingTileStatus
    let progress: Double
    /// The tile's address: "z7/67/45".
    let title: String
    /// What the tile is doing or has become, and for how long once that
    /// is worth saying: "parse 12s", "displayed".
    let statusText: String
    /// Every preparation stage with its time, in order: "disk 3ms · parse
    /// 62ms · ready". Empty before the first stage.
    let stagesText: String
    /// The parse's dearest layers, `layerCount` at most, the dearest
    /// first: "landuse 46ms · roads 7ms". Empty until the parse reports.
    let layersText: String

    static let layerCount = 3
    /// A live stage younger than this shows no age: every card would
    /// flicker a "0s" or "1s" for the moment it takes a healthy stage to
    /// pass.
    static let stageAgeDisplayThreshold = 2
    static let separator = " · "

    init(_ snapshot: TileLoadingStatusTileSnapshot) {
        tile = snapshot.tile
        status = snapshot.status
        progress = snapshot.progress
        title = "z\(snapshot.tile.z)/\(snapshot.tile.x)/\(snapshot.tile.y)"
        let detail = snapshot.detail.isEmpty ? Self.statusText(snapshot.status) : snapshot.detail
        let age = snapshot.stageAgeSeconds >= Self.stageAgeDisplayThreshold ? " \(snapshot.stageAgeSeconds)s" : ""
        statusText = detail + age
        stagesText = snapshot.preparationStages.map { stage in
            stage.duration.map { "\(stage.name) \(Self.millisecondsDescription($0))" } ?? stage.name
        }.joined(separator: Self.separator)
        let timings = snapshot.preparationStages.first { $0.name == "parse" }?.layerTimings ?? []
        layersText = timings.sorted { $0.duration > $1.duration }.prefix(Self.layerCount)
            .map { "\($0.layerName) \(Self.millisecondsDescription($0.duration))" }
            .joined(separator: Self.separator)
    }

    /// The first line: the address and the status.
    var headline: String { "\(title) \(statusText)" }

    /// The card's text line by line, the empty lines left out.
    var lines: [String] { [headline, stagesText, layersText].filter { $0.isEmpty == false } }

    /// The cards of the list: the deepest zoom first, since those are the
    /// tiles on screen, and the tiles of a zoom by their address, so a tile
    /// is found where it was last time whatever order the loader reports
    /// them in.
    static func cards(for tiles: [TileLoadingStatusTileSnapshot]) -> [DebugOverlayTileCard] {
        tiles.sorted { a, b in
            if a.tile.z != b.tile.z { return a.tile.z > b.tile.z }
            if a.tile.x != b.tile.x { return a.tile.x < b.tile.x }
            return a.tile.y < b.tile.y
        }.map(DebugOverlayTileCard.init)
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

/// The geometry of a tile card, shared by the platform views: both draw
/// the card by hand, so its measures live in one place. A card is a
/// rounded block with a stripe of the status colour down its left edge,
/// the address and the status on its first line, the stages on its
/// second, the dearest parse layers on its third, and a thin progress bar
/// along its bottom. The cards fill the list's width in as many columns
/// as `minimumWidth` allows (`DebugOverlayPanelLayout.cardColumnCount`).
enum DebugOverlayTileCardLayout {
    static let height: CGFloat = 72
    static let spacing: CGFloat = 6
    static let minimumWidth: CGFloat = 250
    static let cornerRadius: CGFloat = 8
    static let inset: CGFloat = 12
    static let stripeWidth: CGFloat = 4
    static let titleTop: CGFloat = 7
    static let stagesTop: CGFloat = 29
    static let layersTop: CGFloat = 46
    static let progressHeight: CGFloat = 3
    static let progressBottomInset: CGFloat = 6
    static let titleFontSize: CGFloat = 13.5
    static let detailFontSize: CGFloat = 11
    static let backgroundAlpha: CGFloat = 0.32
    static let tintAlpha: CGFloat = 0.16
    static let progressTrackAlpha: CGFloat = 0.35
    static let progressAlpha: CGFloat = 0.9
    /// The gap between the title and the status on the first line.
    static let titleStatusGap: CGFloat = 8

    static func stripeRect(in card: CGRect) -> CGRect {
        CGRect(x: card.minX, y: card.minY, width: stripeWidth, height: card.height)
    }

    static func progressTrackRect(in card: CGRect) -> CGRect {
        CGRect(x: card.minX + inset,
               y: card.maxY - progressBottomInset - progressHeight,
               width: max(0, card.width - inset * 2),
               height: progressHeight)
    }

    static func progressRect(in card: CGRect, progress: Double) -> CGRect {
        let track = progressTrackRect(in: card)
        let share = CGFloat(min(1, max(0, progress)))
        return CGRect(x: track.minX, y: track.minY, width: max(progressHeight, track.width * share), height: track.height)
            .intersection(track)
    }

    static func titleRect(in card: CGRect, lineHeight: CGFloat, statusWidth: CGFloat) -> CGRect {
        CGRect(x: card.minX + inset,
               y: card.minY + titleTop,
               width: max(0, card.width - inset * 2 - statusWidth - titleStatusGap),
               height: lineHeight)
    }

    /// The status, right-aligned on the title's line and centred on it.
    static func statusRect(in card: CGRect, titleLineHeight: CGFloat, lineHeight: CGFloat, width: CGFloat) -> CGRect {
        CGRect(x: card.maxX - inset - width,
               y: card.minY + titleTop + (titleLineHeight - lineHeight) * 0.5,
               width: width,
               height: lineHeight)
    }

    static func stagesRect(in card: CGRect, lineHeight: CGFloat) -> CGRect {
        CGRect(x: card.minX + inset, y: card.minY + stagesTop, width: max(0, card.width - inset * 2), height: lineHeight)
    }

    static func layersRect(in card: CGRect, lineHeight: CGFloat) -> CGRect {
        CGRect(x: card.minX + inset, y: card.minY + layersTop, width: max(0, card.width - inset * 2), height: lineHeight)
    }
}

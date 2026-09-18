// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Foundation
import QuartzCore
import XCTest

/// The debug HUD's tile list must never fall behind the loader.
///
/// A frame publishes a tile-list snapshot at most once per
/// `DebugOverlayHUDSnapshotThrottler.defaultMinimumInterval`, the render loop
/// is on demand, and a landing tile requests exactly one frame. When that
/// frame falls inside the throttle window no snapshot is built, the loop
/// sleeps, and the panel would show the burst's previous state (a tile at
/// "parse" or "disk") for as long as the camera stands still. The panel's
/// timer therefore refreshes the rows from the reporter between frames.
///
/// The pieces here are the production ones (loader, reporter, throttler,
/// store, pacing); only the frame's and the timer's call sequence is
/// restated, because the engine needs a compiled shader library and the
/// panel a host view.
final class DebugOverlayHUDLiveTileRowsTests: XCTestCase {
    private let tile = Tile(x: 77, y: 40, z: 7)

    func testARowLandingInsideTheThrottleWindowIsRefreshedByTheTimerWhileTheLoopSleeps() async {
        var settings = ImmersiveMapSettings.default
        settings.debug.enableDebugPanel = true
        settings.tiles.network.maxConcurrentFetches = 1
        let reporter = TileLoadingStatusReporter()
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        var frame = ReplayedHUDFrame(settings: settings, reporter: reporter)
        var panel = ReplayedHUDPanel(store: frame.store)

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        pipeline.completeDownload(tile, result: .success(Data([1]), etag: "A"))
        let parseStarted = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(parseStarted)

        // Frame N, while the tile parses: the first snapshot is never throttled.
        XCTAssertTrue(frame.render())
        panel.tick()
        XCTAssertEqual(panel.shownRow(for: tile)?.detail, "parse")

        // The parse ends, the tile lands (one frame requested), and frame
        // N+1 renders on the next vsync, inside the window: no snapshot.
        pipeline.completePrepare(tile)
        let materializeStarted = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(materializeStarted)
        frame.pacing.requestOneFrame(reason: .tileAvailable)
        pipeline.completeMaterialize(tile, result: true)
        let publishedOnLanding = frame.render()
        XCTAssertFalse(publishedOnLanding, "the landing frame fell inside the throttle window")
        XCTAssertTrue(frame.pacing.shouldPauseDisplayLink, "the request is consumed, the loop sleeps")

        // The loader finishes on its own task; nothing requests a frame.
        let saved = await pipeline.waitUntilSaved(tile)
        XCTAssertTrue(saved)
        let ready = await reporter.waitUntilRow(for: tile, hasDetail: "ready")
        XCTAssertEqual(ready?.detail, "ready")
        XCTAssertFalse(frame.pacing.needsFrameRendering)

        // The panel's next tick reads the reporter itself.
        panel.tick()
        XCTAssertEqual(panel.shownRow(for: tile)?.detail, "ready")
        XCTAssertEqual(panel.appliedCount, 2, "one frame snapshot, one between-frames refresh")

        // A quiet loader costs the panel nothing more.
        panel.tick()
        XCTAssertEqual(panel.appliedCount, 2)
        loader.cancelAll()
    }

    func testARowThatReallyStaysInAStageShowsItsAgeGrowing() async {
        var settings = ImmersiveMapSettings.default
        settings.debug.enableDebugPanel = true
        settings.tiles.network.maxConcurrentFetches = 1
        var now: TimeInterval = 1000
        let reporter = TileLoadingStatusReporter(now: { now })
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        var frame = ReplayedHUDFrame(settings: settings, reporter: reporter)
        var panel = ReplayedHUDPanel(store: frame.store)

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        pipeline.completeDownload(tile, result: .success(Data([1]), etag: "A"))
        let parseStarted = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(parseStarted)
        XCTAssertTrue(frame.render())
        panel.tick()
        XCTAssertEqual(panel.shownRowText(for: tile), "  z7/77/40 parse")

        // No frame follows, the parse does not end: the row ages on screen.
        now = 1012
        panel.tick()
        XCTAssertEqual(panel.shownRowText(for: tile), "  z7/77/40 parse 12s")

        loader.cancelAll()
        pipeline.completePrepare(tile)
    }
}

// MARK: - The frame and the panel, reduced to their HUD work

/// What one rendered frame does with the HUD and the pacing, lifted from
/// `RenderFrameEngine.publishDebugOverlayHUDSnapshot` (the throttler gate,
/// the reporter snapshot, the publish into `DebugOverlayHUDSnapshotStore`)
/// and `ImmersiveMapRenderDriver.renderFrame` (the consumed frame request).
private struct ReplayedHUDFrame {
    let pacing: RenderLoopPacing
    let store = DebugOverlayHUDSnapshotStore()
    private let settings: ImmersiveMapSettings
    private let reporter: TileLoadingStatusReporter
    private var throttler = DebugOverlayHUDSnapshotThrottler()

    init(settings: ImmersiveMapSettings, reporter: TileLoadingStatusReporter) {
        self.settings = settings
        self.reporter = reporter
        self.pacing = RenderLoopPacing(configuration: settings.renderLoop)
        // What `RenderFrameEngine.init` does through the event sink.
        store.attachTileLoadingStatus(provider: { [reporter] in reporter.snapshot() })
    }

    /// Returns whether the frame published a snapshot.
    mutating func render() -> Bool {
        var published = false
        if throttler.shouldBuildSnapshot(isEnabled: settings.debug.enableDebugPanel, at: CACurrentMediaTime()) {
            store.publish(DebugOverlayHUDSnapshot.make(settings: settings.debug,
                                                       zoom: 10,
                                                       latitude: 0,
                                                       longitude: 0,
                                                       cameraDebugLines: [],
                                                       diagnostics: nil,
                                                       tileLoadingStatus: reporter.snapshot()))
            published = true
        }
        pacing.consumeOneFrameRequest()
        return published
    }
}

/// The panel's 0.2 s timer, lifted from
/// `ImmersiveMapDebugOverlayRuntime.flushPendingHUDSnapshot`: the newest
/// frame snapshot when there is one, otherwise the between-frames refresh.
private struct ReplayedHUDPanel {
    private let store: DebugOverlayHUDSnapshotStore
    private var consumedVersion: UInt64 = 0
    private var applied: DebugOverlayHUDSnapshot?
    private(set) var appliedCount = 0

    init(store: DebugOverlayHUDSnapshotStore) {
        self.store = store
    }

    mutating func tick() {
        if let value = store.consumeLatest(after: consumedVersion) {
            consumedVersion = value.version
            applied = value.snapshot
            appliedCount += 1
            return
        }
        if let refreshed = store.refreshedSnapshot(applying: applied) {
            applied = refreshed
            appliedCount += 1
        }
    }

    func shownRow(for tile: Tile) -> TileLoadingStatusTileSnapshot? {
        applied?.tileLoadingStatusTiles.first { $0.tile == tile }
    }

    func shownRowText(for tile: Tile) -> String? {
        shownRow(for: tile).map { DebugOverlayTilesStatusRow.tile($0, isExpanded: false, canExpand: false).text }
    }
}

private extension TileLoadingStatusReporter {
    func waitUntilRow(for tile: Tile, hasDetail detail: String) async -> TileLoadingStatusTileSnapshot? {
        for _ in 0..<500 {
            if let row = snapshot().tiles.first(where: { $0.tile == tile }), row.detail == detail {
                return row
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return snapshot().tiles.first { $0.tile == tile }
    }
}

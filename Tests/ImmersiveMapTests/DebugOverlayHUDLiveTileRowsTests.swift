// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Foundation
import QuartzCore
import XCTest

/// The debug HUD's tile list must never fall behind the loader.
///
/// Every rendered frame publishes a tile-list snapshot, but the render
/// loop is on demand: a landing tile requests one frame, the loader then
/// finishes on its own task, and no frame follows. Without a word from
/// the reporter the panel would show the burst's previous state (a tile at
/// "parse" or "disk") for as long as the camera stands still. The reporter
/// therefore announces every change (`onChange`), and the panel reads the
/// rows again between frames.
///
/// The pieces here are the production ones (loader, reporter, store,
/// pacing); only the frame's and the panel's call sequence is restated,
/// because the engine needs a compiled shader library and the panel a
/// host view.
final class DebugOverlayHUDLiveTileRowsTests: XCTestCase {
    private let tile = Tile(x: 77, y: 40, z: 7)

    func testARowLandingAfterTheLastFrameIsRefreshedOnTheReportersWordWhileTheLoopSleeps() async {
        var settings = ImmersiveMapSettings.default
        settings.debug.enableDebugPanel = true
        settings.tiles.network.maxConcurrentFetches = 1
        let reporter = TileLoadingStatusReporter()
        let pipeline = ControlledTileLoadPipeline()
        let loader = ImmersiveMapNeedsTile(config: settings,
                                           loadPipeline: pipeline,
                                           tileLoadingStatusReporter: reporter)
        let frame = ReplayedHUDFrame(settings: settings, reporter: reporter)
        var panel = ReplayedHUDPanel(store: frame.store)
        // What the engine wires: the reporter's word reaches the sink.
        let changes = ChangeCounter()
        reporter.onChange = { changes.increment() }

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        pipeline.completeDownload(tile, result: .success(Data([1]), etag: "A"))
        let parseStarted = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(parseStarted)

        // Frame N, while the tile parses: the panel applies its snapshot.
        frame.render()
        panel.tick()
        XCTAssertEqual(panel.shownRow(for: tile)?.detail, "parse")

        // The parse ends, the tile lands (one frame requested), and frame
        // N+1 renders on the next vsync with the tile still materializing.
        pipeline.completePrepare(tile)
        let materializeStarted = await pipeline.waitUntilMaterialized(tile)
        XCTAssertTrue(materializeStarted)
        frame.pacing.requestOneFrame(reason: .tileAvailable)
        frame.render()
        panel.tick()
        XCTAssertTrue(frame.pacing.shouldPauseDisplayLink, "the request is consumed, the loop sleeps")
        let changesBeforeLanding = changes.count

        // The materialization ends and the loader finishes on its own
        // task; nothing requests a frame, but the reporter says it moved.
        pipeline.completeMaterialize(tile, result: true)
        let saved = await pipeline.waitUntilSaved(tile)
        XCTAssertTrue(saved)
        let ready = await reporter.waitUntilRow(for: tile, hasDetail: "ready")
        XCTAssertEqual(ready?.detail, "ready")
        XCTAssertFalse(frame.pacing.needsFrameRendering)
        // The reporter writes the row under its queue and speaks outside it,
        // so the row reads "ready" a moment before the word of it arrives:
        // the word is waited for, not assumed to have come with the row.
        let announced = await waitUntil { changes.count > changesBeforeLanding }
        XCTAssertTrue(announced, "The reporter announced the landing")

        // The panel's refresh on that word reads the reporter itself.
        let appliedBefore = panel.appliedCount
        panel.tick()
        XCTAssertEqual(panel.shownRow(for: tile)?.detail, "ready")
        XCTAssertEqual(panel.appliedCount, appliedBefore + 1, "one between-frames refresh")

        // A quiet loader costs the panel nothing more.
        panel.tick()
        XCTAssertEqual(panel.appliedCount, appliedBefore + 1)
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
        let frame = ReplayedHUDFrame(settings: settings, reporter: reporter)
        var panel = ReplayedHUDPanel(store: frame.store)

        loader.request(tiles: [tile])
        let downloadStarted = await pipeline.waitUntilStarted(tile)
        XCTAssertTrue(downloadStarted)
        pipeline.completeDownload(tile, result: .success(Data([1]), etag: "A"))
        let parseStarted = await pipeline.waitUntilPrepared(tile)
        XCTAssertTrue(parseStarted)
        frame.render()
        panel.tick()
        XCTAssertEqual(panel.shownRowText(for: tile), "z7/77/40 parse")

        // No frame follows, the parse does not end: the row ages on screen.
        now = 1012
        panel.tick()
        XCTAssertEqual(panel.shownRowText(for: tile), "z7/77/40 parse 12s")

        loader.cancelAll()
        pipeline.completePrepare(tile)
    }
}

// MARK: - The frame and the panel, reduced to their HUD work

/// What one rendered frame does with the HUD and the pacing, lifted from
/// `RenderFrameEngine.publishDebugOverlayHUDSnapshot` (the throttler gate,
/// the reporter snapshot, the publish into `DebugOverlayHUDSnapshotStore`)
/// and `ImmersiveMapRenderDriver.renderFrame` (the consumed frame request).
private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private struct ReplayedHUDFrame {
    let pacing: RenderLoopPacing
    let store = DebugOverlayHUDSnapshotStore()
    private let settings: ImmersiveMapSettings
    private let reporter: TileLoadingStatusReporter

    init(settings: ImmersiveMapSettings, reporter: TileLoadingStatusReporter) {
        self.settings = settings
        self.reporter = reporter
        self.pacing = RenderLoopPacing(configuration: settings.renderLoop)
        // What `RenderFrameEngine.init` does through the event sink.
        store.attachTileLoadingStatus(provider: { [reporter] in reporter.snapshot() })
    }

    /// Every rendered frame publishes its snapshot.
    func render() {
        store.publish(DebugOverlayHUDSnapshot.make(settings: settings.debug,
                                                   zoom: 10,
                                                   latitude: 0,
                                                   longitude: 0,
                                                   cameraDebugLines: [],
                                                   diagnostics: nil,
                                                   tileLoadingStatus: reporter.snapshot()))
        pacing.consumeOneFrameRequest()
    }
}

/// The panel's flush, lifted from
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
        shownRow(for: tile).map { DebugOverlayTileCard($0).headline }
    }
}

/// Polls `condition` for up to five seconds, since the loader finishes on
/// its own task and the test has no handle to await.
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
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

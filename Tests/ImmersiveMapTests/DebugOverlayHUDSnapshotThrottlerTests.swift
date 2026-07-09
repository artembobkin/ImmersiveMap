// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class DebugOverlayHUDSnapshotThrottlerTests: XCTestCase {
    func testBuildCadenceSkipsBeforeMinimumIntervalWithoutRequiringSnapshot() {
        var throttler = DebugOverlayHUDSnapshotThrottler(minimumInterval: 0.2)

        XCTAssertTrue(throttler.shouldBuildSnapshot(isEnabled: true, at: 1.0))
        XCTAssertFalse(throttler.shouldBuildSnapshot(isEnabled: true, at: 1.1))
        XCTAssertTrue(throttler.shouldBuildSnapshot(isEnabled: true, at: 1.2))
    }

    func testBuildCadenceDoesNotPublishDisabledStateEveryFrame() {
        var throttler = DebugOverlayHUDSnapshotThrottler(minimumInterval: 0.2)

        XCTAssertFalse(throttler.shouldBuildSnapshot(isEnabled: false, at: 1.0))
        XCTAssertFalse(throttler.shouldBuildSnapshot(isEnabled: false, at: 1.1))
        XCTAssertTrue(throttler.shouldBuildSnapshot(isEnabled: true, at: 1.12))
    }

    func testPublishesFirstSnapshotAndThrottlesSubsequentSnapshots() {
        var throttler = DebugOverlayHUDSnapshotThrottler(minimumInterval: 0.2)
        let snapshot = makeSnapshot(zoom: "z: 4.62")

        XCTAssertTrue(throttler.shouldPublish(snapshot: snapshot, at: 1.0))
        XCTAssertFalse(throttler.shouldPublish(snapshot: snapshot, at: 1.1))
        XCTAssertTrue(throttler.shouldPublish(snapshot: snapshot, at: 1.2))
    }

    func testNilSnapshotPublishesImmediatelyAndResetsCadence() {
        var throttler = DebugOverlayHUDSnapshotThrottler(minimumInterval: 0.2)
        let snapshot = makeSnapshot(zoom: "z: 4.62")

        XCTAssertTrue(throttler.shouldPublish(snapshot: snapshot, at: 1.0))
        XCTAssertFalse(throttler.shouldPublish(snapshot: snapshot, at: 1.1))
        XCTAssertTrue(throttler.shouldPublish(snapshot: nil, at: 1.11))
        XCTAssertTrue(throttler.shouldPublish(snapshot: snapshot, at: 1.12))
    }

    private func makeSnapshot(zoom: String) -> DebugOverlayHUDSnapshot {
        let settings = ImmersiveMapSettings.default.debug
        return DebugOverlayHUDSnapshot(
            coordinateLines: DebugOverlayCoordinateLines(zoom: zoom, latLon: "lat: 55.756 lon: 37.617"),
            diagnosticsLines: ["frame:1 dt:16.67ms fps:60.0"],
            atlasPages: [],
            tileLoadingStatusLines: [],
            tileLoadingStatusTiles: [],
            coordinateScale: settings.coordinateScale,
            diagnosticsScale: settings.diagnosticsScale,
            leftPadding: settings.leftPadding,
            topPadding: settings.topPadding,
            sectionSpacing: settings.sectionSpacing,
            textColor: settings.textColor
        )
    }
}

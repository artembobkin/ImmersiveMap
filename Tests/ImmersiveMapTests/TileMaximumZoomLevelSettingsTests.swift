// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The depth the map asks the archive for: the archive's own, read from its
/// header and kept on disk (`TileArchiveDepths`), under an optional cap
/// (`tileMaximumZoomLevel(_:)`). `@MainActor` like every other suite that
/// builds an `ImmersiveMapView`.
@MainActor
final class TileMaximumZoomLevelSettingsTests: XCTestCase {
    private typealias Coverage = ImmersiveMapSettings.TileSettings.CoverageSettings

    /// A caches folder of the test's own, removed after it.
    private func cachesDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A map states nothing about the depth: no cap, and until the
    /// archive's header was read, the hosted archive's depth.
    func testByDefaultTheArchiveDecides() {
        let coverage = ImmersiveMapSettings.default.tiles.coverage
        XCTAssertNil(coverage.maximumZoomLevel)
        XCTAssertNil(coverage.archiveMaximumZoomLevel)
        XCTAssertEqual(coverage.resolvedMaximumZoomLevel, ImmersiveMapTilesService.maximumTileZoomLevel)
    }

    /// The archive's depth, under the cap when there is one, and the cap
    /// alone while the depth is unknown.
    func testTheDepthIsTheArchivesUnderTheCap() {
        func resolved(cap: Int?, archive: Int?) -> Int {
            var coverage = Coverage(maximumZoomLevel: cap)
            coverage.archiveMaximumZoomLevel = archive
            return coverage.resolvedMaximumZoomLevel
        }
        XCTAssertEqual(resolved(cap: nil, archive: 14), 14, "A shallower archive")
        XCTAssertEqual(resolved(cap: nil, archive: 16), 16, "A deeper archive")
        XCTAssertEqual(resolved(cap: 13, archive: 16), 13, "Capped")
        XCTAssertEqual(resolved(cap: 18, archive: 14), 14, "Never past the archive")
        XCTAssertEqual(resolved(cap: 13, archive: nil), 13, "The cap before the header is read")
    }

    func testTheModifierSetsAndClearsTheCap() {
        let capped = ImmersiveMapSettings.default.tileMaximumZoomLevel(14)
        XCTAssertEqual(capped.tiles.coverage.maximumZoomLevel, 14)
        XCTAssertNil(capped.tileMaximumZoomLevel(nil).tiles.coverage.maximumZoomLevel)

        let view = ImmersiveMapView().tileMaximumZoomLevel(18)
        XCTAssertEqual(view.settings.tiles.coverage.maximumZoomLevel, 18)
    }

    /// The coverage asks for no tile past the depth.
    func testCoverageResolutionHonorsTheDepth() {
        var tiles = ImmersiveMapSettings.default.tiles
        tiles.coverage.archiveMaximumZoomLevel = 14
        XCTAssertEqual(tiles.resolvedCoverageZoomLevel(forCameraZoom: 13.4), 13)
        XCTAssertEqual(tiles.resolvedCoverageZoomLevel(forCameraZoom: 18.7), 14, "Past the archive's depth")
    }

    /// The depth read once is kept on disk for the next start, and posted
    /// only when it changes.
    func testTheDepthIsKeptAndAChangeIsPosted() {
        let caches = cachesDirectory()
        let depths = TileArchiveDepths(baseCachesDirectory: caches)
        let revision: UInt64 = 0xABC
        XCTAssertNil(depths.maximumZoom(sourceRevision: revision), "Never read")

        let posted = expectation(forNotification: TileArchiveDepths.didChange, object: nil)
        depths.observe(maximumZoom: 14, sourceRevision: revision)
        wait(for: [posted], timeout: 2)
        XCTAssertEqual(depths.maximumZoom(sourceRevision: revision), 14)

        let nextStart = TileArchiveDepths(baseCachesDirectory: caches)
        XCTAssertEqual(nextStart.maximumZoom(sourceRevision: revision), 14, "Read back from disk")
        XCTAssertNil(nextStart.maximumZoom(sourceRevision: 0xDEF), "Another archive")

        let unchanged = expectation(forNotification: TileArchiveDepths.didChange, object: nil)
        unchanged.isInverted = true
        nextStart.observe(maximumZoom: 14, sourceRevision: revision)
        wait(for: [unchanged], timeout: 0.3)
    }

    /// The settings a map is built from carry the depth kept for their
    /// archive, and a change of it rebuilds the renderer, which parses by it.
    func testTheSettingsCarryTheKeptDepthAndAChangeRebuilds() {
        let depths = TileArchiveDepths(baseCachesDirectory: cachesDirectory())
        let settings = ImmersiveMapSettings.default
            .tileArchive(URL(string: "https://tiles.example.com/planet.pmtiles")!)
        let revision = PreparedTileCacheIdentity.tileSourceRevision(for: settings.tiles.network)
        XCTAssertNil(settings.resolvingArchiveDepth(depths).tiles.coverage.archiveMaximumZoomLevel)

        depths.observe(maximumZoom: 14, sourceRevision: revision)
        let resolved = settings.resolvingArchiveDepth(depths)
        XCTAssertEqual(resolved.tiles.coverage.resolvedMaximumZoomLevel, 14)
        XCTAssertEqual(TileParseOptions(settings: resolved).buildingDeepestSourceZoom, 14, "The parse reads it")

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: settings, to: resolved)
        XCTAssertTrue(plan.requiresRendererRecreation)

        let margin = ImmersiveMapSettingsApplicationPlanner.makePlan(from: resolved,
                                                                     to: resolved.tileCoverage(rasterBandMarginShare: 0.5))
        XCTAssertEqual(margin.actions, [.liveApply], "The rest of the coverage applies live")
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Foundation
import PMTiles
import PMTilesTestSupport

/// The tile service the test suite renders from: one pre-built fixture
/// archive, served over loopback by this process, for the whole run.
///
/// The suite must never fetch a tile from the real service. A test that does
/// is three tests in one: it asserts what it meant to, plus that the machine
/// has a network, plus that a CDN answered in time with the planet build the
/// assertion was written against. Those extra two fail on aeroplanes, on
/// rate-limited runners and on the day the planet is rebuilt, and they fail as
/// the original assertion, which is the worst way to learn any of it.
///
/// Everything below the transport stays real. The bytes travel the whole
/// loader path (range request, header, directory, ETag, gzip, parse,
/// tessellate, materialize) exactly as a hosted archive's would. Only where
/// they come from changes. The tiles themselves are built by
/// `VectorTileFixture` at start-up rather than checked in as blobs, so what
/// they contain can be read in the source.
///
/// One listener serves the whole process: the port is part of the tile source
/// identity, so a port per test would give every test its own cache namespace
/// for nothing.
final class FixtureTileService: @unchecked Sendable {
    static let shared = FixtureTileService()

    /// The archive URL to point the tile network settings at, or nil when the
    /// listener never came up. `FixtureTileServiceTests` is where that
    /// failure is reported; the settings helpers below stay offline either
    /// way, they just have no tiles to serve.
    let archiveURL: URL?

    /// The archive as served, for a test that wants to read it back.
    let archiveData: Data

    /// The ETag the server answers with.
    static let etag = "\"immersive-map-test-fixture\""

    private let server: LocalTileServer?

    private init() {
        archiveData = Self.makeArchive()
        let archive = LocalTileServer.Resource.archive(archiveData, etag: Self.etag)
        let server = try? LocalTileServer(route: { request in
            request.path == LocalTileServer.archivePath ? archive : nil
        })
        self.server = server
        archiveURL = server?.archiveURL
    }

    /// One tile, stored once, addressed by every coordinate of every zoom.
    ///
    /// A single polygon covering the whole tile, tagged as water, is enough
    /// for every case that needs "the map has ground on it": it paints the
    /// same wherever the camera happens to look, so no test has to reason
    /// about which tile its viewport landed on. The directory says so in
    /// sixteen entries: at zoom z the ids run from `(4^z - 1) / 3` for `4^z`
    /// tiles, and one run-length entry per zoom points them all at the one
    /// stored tile.
    private static func makeArchive() -> Data {
        let tileBody = VectorTileFixture.fullCoverageTile(layerName: "water",
                                                          properties: ["kind": "water"])
        let stored = PMTilesArchiveWriter.gzip(tileBody)
        var writer = PMTilesArchiveWriter()
        writer.tileCompression = .gzip
        writer.explicitTileData = stored
        writer.explicitEntries = (0...15).map { zoom in
            let tileCount = UInt64(1) << UInt64(2 * zoom)
            return PMTilesEntry(tileID: (tileCount - 1) / 3,
                                offset: 0,
                                length: UInt32(stored.count),
                                runLength: UInt32(tileCount))
        }
        writer.minZoom = 0
        writer.maxZoom = 15
        return writer.serializedData()
    }
}

/// How a test says where its tiles come from. Every test that builds a map
/// runtime (a host view, a still capture, a video export, the offscreen
/// harness) takes its settings from here.
enum FixtureTiles {
    /// Settings served by the in-process fixture service: a frame rendered
    /// under these can have real tiles on it, and no request leaves the
    /// machine.
    static func settings(_ settings: ImmersiveMapSettings = .default) -> ImmersiveMapSettings {
        guard let archiveURL = FixtureTileService.shared.archiveURL else {
            // The listener failed. Falling back to the dead port keeps the
            // guarantee that matters (nothing reaches the network); the
            // missing tiles are reported by `FixtureTileServiceTests`.
            return tilelessSettings(settings)
        }
        return cacheless(sourced(settings, archiveURL: archiveURL))
    }

    /// Settings under which no tile can ever reach a frame: the archive
    /// points at a port nothing listens on, so the loader fails immediately
    /// and locally (connection refused on 127.0.0.1, no DNS, no traffic).
    ///
    /// This is what a case wants when the picture has to be a pure function of
    /// the scene: two frames rendered a sixtieth of a second apart must not
    /// differ because a tile landed between them.
    static func tilelessSettings(_ settings: ImmersiveMapSettings = .default) -> ImmersiveMapSettings {
        cacheless(sourced(settings, archiveURL: deadEndArchiveURL))
    }

    /// Port 1 is reserved and unused; nothing on the machine listens there.
    static let deadEndArchiveURL = URL(string: "http://127.0.0.1:1/planet.pmtiles")!

    /// Points the network settings at the given archive the same way the
    /// shipped defaults point at the hosted one.
    private static func sourced(_ settings: ImmersiveMapSettings, archiveURL: URL) -> ImmersiveMapSettings {
        var sourced = settings
        sourced.tiles.network.tileArchiveURL = archiveURL
        return sourced
    }

    /// Both disk caches off, and downloaded regions ignored.
    ///
    /// The caches for two reasons: a test run must leave nothing behind in the
    /// user's Caches directory, and a run must not be able to read what an
    /// earlier one wrote. A warm prepared-tile cache is a way for yesterday's
    /// tiles to appear in today's frame, which is the same non-determinism the
    /// network was removed to avoid.
    ///
    /// The regions because `DefaultTileLoadPipeline` otherwise builds an
    /// `OfflineTileStore` rooted in the user's real Application Support
    /// directory, and in `.automatic` mode consults it on every failed
    /// download. Nothing in the suite writes there, so today it only ever
    /// reads, but a store the tests never populate has no business being
    /// consulted by them at all.
    private static func cacheless(_ settings: ImmersiveMapSettings) -> ImmersiveMapSettings {
        var cacheless = settings
        cacheless.tiles.cache.urlCacheEnabled = false
        cacheless.tiles.cache.preparedTileCacheEnabled = false
        cacheless.tiles.offline.mode = .disabled
        prewarmSharedRenderResourcesIfPossible()
        return cacheless
    }

    /// A map view builds its renderer only once the process holds the
    /// shared GPU resources, on a background task otherwise, which would
    /// leave every test that reads the renderer right after making a view
    /// looking at nil. The tests keep their synchronous contract by holding
    /// the default resource set before the first view: built here, once,
    /// where every fixture settings value is made. Nothing to build without
    /// the compiled shaders; the Metal-backed tests skip themselves then.
    private static func prewarmSharedRenderResourcesIfPossible() {
        guard Thread.isMainThread,
              MetalTestEnvironment.unavailabilityReason() == nil else {
            return
        }
        MainActor.assumeIsolated {
            _ = SharedRenderResources.shared()
        }
    }
}

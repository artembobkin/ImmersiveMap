// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Foundation

/// The tile service the test suite renders from: pre-loaded fixture tiles,
/// served over loopback by this process, for the whole run.
///
/// The suite must never fetch a tile from the real service. A test that does
/// is three tests in one: it asserts what it meant to, plus that the machine
/// has a network, plus that a CDN answered in time with the planet build the
/// assertion was written against. Those extra two fail on aeroplanes, on
/// rate-limited runners and on the day the planet is rebuilt, and they fail as
/// the original assertion, which is the worst way to learn any of it.
///
/// Everything below the transport stays real. The bytes travel the whole
/// loader path (URL, HTTP, ETag, parse, tessellate, materialize) exactly as a
/// downloaded tile would; only where they come from changes. The tiles
/// themselves are built by `VectorTileFixture` at start-up rather than checked
/// in as blobs, so what they contain can be read in the source.
///
/// One listener serves the whole process: the port is part of the tile source
/// identity, so a port per test would give every test its own cache namespace
/// and its own TileJSON discovery request for nothing.
final class FixtureTileService: @unchecked Sendable {
    static let shared = FixtureTileService()

    /// The base URL to hand to `ImmersiveMapTilesProvider`, or nil when the
    /// listener never came up. `FixtureTileServiceTests` is where that
    /// failure is reported; the settings helpers below stay offline either
    /// way, they just have no tiles to serve.
    let tileBaseURL: URL?

    private let server: LocalTileServer?

    private init() {
        // A single polygon covering the whole tile, tagged as water, is enough
        // for every case that needs "the map has ground on it": it paints the
        // same wherever the camera happens to look, so no test has to reason
        // about which tile its viewport landed on.
        guard let tileBody = try? VectorTileFixture.fullCoverageTile(layerName: "water",
                                                                     properties: ["class": "water"]) else {
            server = nil
            tileBaseURL = nil
            return
        }

        // The TileJSON document advertises an absolute template, which cannot
        // be written before the system hands out a port. The box is filled the
        // moment it is known, and the loader's discovery request cannot arrive
        // before then: nothing has the address yet.
        let templateBox = Locked<String?>(nil)
        let server = try? LocalTileServer(route: { path in
            if path.hasSuffix("tiles.json") {
                guard let template = templateBox.withLock({ $0 }),
                      let document = try? JSONSerialization.data(withJSONObject: ["tiles": [template]]) else {
                    return nil
                }
                return .json(document)
            }
            guard path.hasSuffix(".mvt") || path.hasSuffix(".pbf") else {
                return nil
            }
            return .protobuf(tileBody)
        })
        self.server = server
        tileBaseURL = server?.tileBaseURL
        if let baseURL = server?.baseURL {
            templateBox.withLock { $0 = "\(baseURL.absoluteString)/v/fixture/tiles/{z}/{x}/{y}.pbf" }
        }
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
        guard let tileBaseURL = FixtureTileService.shared.tileBaseURL else {
            // The listener failed. Falling back to the dead port keeps the
            // guarantee that matters (nothing reaches the network); the
            // missing tiles are reported by `FixtureTileServiceTests`.
            return tilelessSettings(settings)
        }
        return cacheless(settings.tileProvider(ImmersiveMapTilesProvider(tileBaseURL: tileBaseURL)))
    }

    /// Settings under which no tile can ever reach a frame: the provider
    /// points at a port nothing listens on, so the loader fails immediately
    /// and locally (connection refused on 127.0.0.1, no DNS, no traffic).
    ///
    /// This is what a case wants when the picture has to be a pure function of
    /// the scene: two frames rendered a sixtieth of a second apart must not
    /// differ because a tile landed between them.
    static func tilelessSettings(_ settings: ImmersiveMapSettings = .default) -> ImmersiveMapSettings {
        cacheless(settings.tileProvider(ImmersiveMapTilesProvider(tileBaseURL: deadEndTileBaseURL)))
    }

    /// Port 1 is reserved and unused; nothing on the machine listens there.
    static let deadEndTileBaseURL = URL(string: "http://127.0.0.1:1/tiles")!

    /// Both disk caches off, for two reasons. A test run must leave nothing
    /// behind in the user's Caches directory, and a run must not be able to
    /// read what an earlier one wrote: a warm prepared-tile cache is a way for
    /// yesterday's tiles to appear in today's frame, which is the same
    /// non-determinism the network was removed to avoid.
    private static func cacheless(_ settings: ImmersiveMapSettings) -> ImmersiveMapSettings {
        var cacheless = settings
        cacheless.tiles.cache.urlCacheEnabled = false
        cacheless.tiles.cache.preparedTileCacheEnabled = false
        return cacheless
    }
}

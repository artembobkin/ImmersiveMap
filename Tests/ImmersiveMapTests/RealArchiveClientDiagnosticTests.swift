// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt
import PMTiles
import XCTest
@testable import ImmersiveMap

/// A manual diagnostic, not part of the suite: reads a few tiles from the
/// live archive through `PMTilesArchiveClient` and prints what came back,
/// so a transport or format problem is seen at the client and not only as
/// a black globe. Skips unless `IMMERSIVEMAP_REAL_TILES_DIAG=1` is set.
/// Needs no Metal, so `swift test --filter RealArchiveClientDiagnosticTests`
/// runs it.
final class RealArchiveClientDiagnosticTests: XCTestCase {
    func testTheLiveArchiveAnswersTileRequests() async throws {
        guard ProcessInfo.processInfo.environment["IMMERSIVEMAP_REAL_TILES_DIAG"] == "1" else {
            throw XCTSkip("Opt-in diagnostic: set IMMERSIVEMAP_REAL_TILES_DIAG=1 to run against the live archive")
        }
        let client = PMTilesArchiveClient(
            archiveURL: ImmersiveMapTilesService.tileArchiveURL,
            requestHeaders: [:],
            session: URLSession(configuration: TileDownloader.makeSessionConfiguration()))
        for (z, x, y) in [(0, 0, 0), (1, 1, 0), (5, 19, 9), (14, 9904, 5121), (15, 19808, 10242)] {
            do {
                let outcome = try await client.tileBytes(z: z, x: x, y: y)
                switch outcome {
                case .tile(let data, let etag):
                    let decoded = try MvtTileDecoder.decode(data: data)
                    let layers = decoded.layers.map { "\($0.name):\($0.features.count)" }
                    print("z\(z)/\(x)/\(y): \(data.count) bytes, etag \(etag ?? "-"), layers \(layers)")
                case .missing:
                    print("z\(z)/\(x)/\(y): missing")
                case .outsideZoomRange:
                    print("z\(z)/\(x)/\(y): outside zoom range")
                }
            } catch {
                XCTFail("z\(z)/\(x)/\(y): \(error)")
            }
        }
    }
}

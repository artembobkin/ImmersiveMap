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

    /// Lists what the live archive ships: per layer and geometry type, every
    /// `kind` and `kind_detail` pair and every property key, with how many
    /// features carry it, over tiles from the world view down to a city
    /// block. The style's coverage is checked against this list.
    func testTheLiveArchiveKindsArePrinted() async throws {
        guard ProcessInfo.processInfo.environment["IMMERSIVEMAP_REAL_TILES_DIAG"] == "1" else {
            throw XCTSkip("Opt-in diagnostic: set IMMERSIVEMAP_REAL_TILES_DIAG=1 to run against the live archive")
        }
        let client = PMTilesArchiveClient(
            archiveURL: ImmersiveMapTilesService.tileArchiveURL,
            requestHeaders: [:],
            session: URLSession(configuration: TileDownloader.makeSessionConfiguration()))
        let tiles = [(0, 0, 0), (2, 2, 1), (4, 9, 5), (5, 19, 9), (6, 38, 19), (7, 77, 38), (8, 154, 76),
                     (10, 619, 320), (12, 2476, 1280), (13, 4952, 2560), (14, 9904, 5121),
                     (15, 19808, 10242), (15, 19806, 10240), (15, 9650, 12318), (15, 16372, 10893)]
        for (z, x, y) in tiles {
            guard case .tile(let data, _) = try await client.tileBytes(z: z, x: x, y: y) else {
                print("z\(z)/\(x)/\(y): no tile")
                continue
            }
            let decoded = try MvtTileDecoder.decode(data: data)
            print("=== z\(z)/\(x)/\(y)")
            for layer in decoded.layers {
                var kinds: [String: Int] = [:]
                var keys: [String: Int] = [:]
                for feature in layer.features {
                    let tags = feature.tags.materializedValues(data: decoded.sourceData)
                    var kind = "-"
                    var detail = "-"
                    var index = 0
                    while index + 1 < tags.count {
                        let key = layer.keys[Int(tags[index])]
                        let value = layer.values[Int(tags[index + 1])]
                        if key == "kind" { kind = value.stringValue ?? "?" }
                        if key == "kind_detail" { detail = value.stringValue ?? "?" }
                        if key.hasPrefix("name:") == false, key.hasPrefix("pgf:") == false {
                            keys[key, default: 0] += 1
                        }
                        index += 2
                    }
                    kinds["\(feature.type) \(kind)/\(detail)", default: 0] += 1
                }
                print("  [\(layer.name)] \(layer.features.count)")
                for (entry, count) in kinds.sorted(by: { $0.key < $1.key }) {
                    print("    \(entry): \(count)")
                }
                print("    keys: \(keys.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
            }
        }
    }
}

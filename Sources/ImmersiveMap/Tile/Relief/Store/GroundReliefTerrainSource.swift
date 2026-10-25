// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import os

/// Where the terrain tiles' heights come from (`GroundReliefStore`): a
/// tile's heights in metres, or word that the source has no such tile.
/// The store knows nothing of URLs, image formats or encodings: a source
/// of another kind (a PMTiles archive, heights already decoded) is a new
/// conformance, and the store does not change.
///
/// A throw is a load that failed and is tried again after a pause that
/// grows with each failure. A tile the source has but cannot be read is
/// no failure of the moment: the source answers `.missing` for it, and
/// the store asks for its ancestor in its place.
protocol GroundReliefTerrainSource: Sendable {
    func heights(of tile: Tile) async throws -> GroundReliefTerrainResponse
}

/// What a terrain source answered for a tile.
enum GroundReliefTerrainResponse: Sendable {
    case heights(GroundReliefHeights)
    /// The source has no terrain tile there.
    case missing
}

/// Terrain tiles as images at a URL template
/// (`GroundReliefSettings.tileURLTemplate`), decoded by their encoding
/// (`GroundReliefSettings.encoding`, `GroundReliefDecoder`). An HTTP 404,
/// or a file that is not there for a terrain directory on disk, is a tile
/// the source does not have.
struct GroundReliefURLTerrainSource: GroundReliefTerrainSource {
    /// What a terrain URL answered.
    enum Fetched: Sendable {
        case image(Data)
        /// The source has no terrain tile there.
        case missing
    }

    private static let logger = Logger(subsystem: "ImmersiveMap", category: "GroundRelief")

    let tileURLTemplate: String
    let encoding: ImmersiveMapSettings.TileSettings.GroundReliefEncoding
    /// The test seam: the bytes at a URL.
    private let fetch: @Sendable (URL) async throws -> Fetched

    init(tileURLTemplate: String,
         encoding: ImmersiveMapSettings.TileSettings.GroundReliefEncoding,
         fetch: @escaping @Sendable (URL) async throws -> Fetched = GroundReliefURLTerrainSource.fetchOverHTTP) {
        self.tileURLTemplate = tileURLTemplate
        self.encoding = encoding
        self.fetch = fetch
    }

    init(settings: ImmersiveMapSettings.TileSettings.GroundReliefSettings,
         fetch: @escaping @Sendable (URL) async throws -> Fetched = GroundReliefURLTerrainSource.fetchOverHTTP) {
        self.init(tileURLTemplate: settings.tileURLTemplate, encoding: settings.encoding, fetch: fetch)
    }

    func heights(of tile: Tile) async throws -> GroundReliefTerrainResponse {
        guard let url = url(for: tile) else {
            return .missing
        }
        switch try await fetch(url) {
        case .image(let data):
            do {
                return .heights(try GroundReliefDecoder.decode(data, encoding: encoding))
            } catch let error as GroundReliefDecoder.Failure {
                Self.logger.warning("ImmersiveMap: terrain tile \(tile.z, privacy: .public)/\(tile.x, privacy: .public)/\(tile.y, privacy: .public) cannot be decoded (\(String(describing: error), privacy: .public)). Check that groundRelief(tileURLTemplate:) serves Terrarium images.")
                return .missing
            }
        case .missing:
            return .missing
        }
    }

    /// The URL of a terrain tile.
    func url(for tile: Tile) -> URL? {
        URL(string: tileURLTemplate
            .replacingOccurrences(of: "{z}", with: String(tile.z))
            .replacingOccurrences(of: "{x}", with: String(tile.x))
            .replacingOccurrences(of: "{y}", with: String(tile.y)))
    }

    /// The terrain at a URL: an HTTP 404, or a file that is not there for a
    /// terrain directory on disk, is a tile the source does not have.
    static func fetchOverHTTP(_ url: URL) async throws -> Fetched {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch let error as URLError where error.code == .fileDoesNotExist {
            return .missing
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .missing
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        switch status {
        case 200 ..< 300:
            return .image(data)
        case 404:
            return .missing
        default:
            throw URLError(.badServerResponse)
        }
    }
}

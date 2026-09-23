// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import PMTiles
import os

/// Throttles a per-tile warning to one line per interval, process wide.
///
/// A blocked viewport is about thirty tiles refused at once, and every one of
/// them carries the same news. Logged per tile it is noise the developer
/// scrolls past; logged once it is the answer to "why is my map full of holes".
/// Process wide rather than per downloader because the quota (or the broken
/// key) belongs to the app, not to whichever downloader happened to notice
/// first. One instance per kind of news, so a rate limit and a rejected
/// credential each get their own line.
/// `@unchecked Sendable` because the lock is the synchronisation the compiler
/// cannot see: the state is private and every path to it goes through `lock`.
final class TileNoticeThrottle: @unchecked Sendable {
    static let rateLimit = TileNoticeThrottle()
    static let authorization = TileNoticeThrottle()
    static let archiveDepth = TileNoticeThrottle()
    static let archiveUnreadable = TileNoticeThrottle()
    static let interval: TimeInterval = 60

    private let lock = NSLock()
    private var lastLoggedAt: Date?

    func shouldLog(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastLoggedAt, now.timeIntervalSince(last) < Self.interval {
            return false
        }
        lastLoggedAt = now
        return true
    }

    /// Test hook: the throttle is process wide, so a test that did not clear it
    /// would be decided by whichever test happened to run first.
    func reset() {
        lock.lock()
        lastLoggedAt = nil
        lock.unlock()
    }
}

/// The transport: one PMTiles archive, read by `PMTilesArchiveClient`, and
/// the archive's answers translated into the loader's download vocabulary.
///
/// `@unchecked Sendable`: every stored property is immutable after `init`,
/// and the client synchronises its own state. The loader and the offline
/// region downloader both call `downloadResult` from many concurrent tasks.
class TileDownloader: @unchecked Sendable {
    private static let logger = Logger(subsystem: "ImmersiveMap", category: "Tiles")

    /// The sentence to show comes from the tile service, not from here. This
    /// engine is MIT and ships compiled inside someone else's app, so its
    /// wording is frozen the day they release; the service is a config reload
    /// away. The fallback covers an endpoint that sends nothing useful.
    static func rateLimitMessage(responseBody: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
           let message = object["message"] as? String,
           message.isEmpty == false {
            return "ImmersiveMap: tile requests are being rate limited. \(message)"
        }
        return "ImmersiveMap: tile requests are being rate limited (HTTP 429), so tiles will be missing until the limit clears."
    }

    /// What to do about a rejected credential, spelled out. The hosted
    /// archive is public and asks for none, so a rejection there points at a
    /// header the request should not have carried. Any other host gets the
    /// generic pointer at the two places a credential can travel. A
    /// server-provided `message` is appended, same convention as the
    /// rate-limit body.
    static func authorizationFailureMessage(statusCode: Int, url: URL?, responseBody: Data) -> String {
        let reason = statusCode == 401 ? "unauthorized" : "forbidden"
        let host = url?.host
        var message = "ImmersiveMap: the tile archive server\(host.map { " at \($0)" } ?? "") returned HTTP \(statusCode) (\(reason))."
        if host?.hasSuffix("immersivemap.dev") == true {
            message += " The hosted archive is public and needs no credential, so check that tileArchive(_:headers:) sends no stale Authorization header."
        } else {
            message += " Check the credential the tile source sends: a key in the archive URL's query, or an Authorization header in tileArchive(_:headers:)."
        }
        message += " Tiles will be missing until the credential is fixed."
        if let object = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
           let serverMessage = object["message"] as? String,
           serverMessage.isEmpty == false {
            message += " The server says: \(serverMessage)"
        }
        return message
    }

    enum DownloadFailure: Equatable, Sendable {
        case missingAuthorizationToken
        case nonHTTPResponse
        case unauthorized
        case forbidden
        case notFound
        case gone
        case rateLimited(retryAfter: TimeInterval?)
        case server(statusCode: Int)
        case client(statusCode: Int)
        case emptyBody
        case network
        /// The archive itself cannot be read: it is not at its URL (404 or
        /// 410 on the archive, not on a tile), or its bytes are not a PMTiles
        /// archive the client understands. Distinct from `.notFound`, which
        /// is one tile the archive does not carry: a missing archive must
        /// back off and retry, never be remembered as a planet of empty tiles.
        case archiveUnavailable
    }

    enum DownloadResult: Equatable, Sendable {
        case success(Data, etag: String?)
        case failure(DownloadFailure)
    }

    private let archive: PMTilesArchiveClient

    init(config: ImmersiveMapSettings) {
        let configuration = Self.makeSessionConfiguration(urlCacheEnabled: config.tiles.cache.urlCacheEnabled,
                                                          maxConcurrentFetches: config.tiles.network.maxConcurrentFetches)
        if config.tiles.cache.clearDiskCachesOnLaunch {
            configuration.urlCache?.removeAllCachedResponses()
        }
        let network = config.tiles.network
        // Nothing is fetched here: the client reads the archive header on
        // the first tile, so building a downloader touches no network.
        archive = PMTilesArchiveClient(archiveURL: network.tileArchiveURL,
                                       requestHeaders: network.tileRequestHeaders,
                                       session: URLSession(configuration: configuration))
    }

    /// The test seam: a client over whatever fetcher the test wants.
    init(archive: PMTilesArchiveClient) {
        self.archive = archive
    }

    static func makeSessionConfiguration(urlCacheEnabled: Bool = true,
                                         maxConcurrentFetches: Int = 5) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        // The loader dispatches up to maxConcurrentFetches tile requests at
        // once; matching the per-host connection cap keeps none of them queued
        // behind Foundation's smaller default when HTTP/1.1 is negotiated.
        // HTTP/2 and HTTP/3 multiplex on fewer connections regardless.
        configuration.httpMaximumConnectionsPerHost = max(1, maxConcurrentFetches)
        // A tile that stops delivering data for 30 s (sliding idle timeout)
        // or takes over 60 s in total has failed for map purposes; the
        // Foundation defaults (60 s idle, 7 days total) would hold one of
        // those slots hostage. The retry controller backs off failed tiles,
        // and the disk stage keeps serving previous content meanwhile.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        if urlCacheEnabled {
            // Kept for a session that answers whole resources. The archive
            // client reads by byte range and bypasses the cache on every
            // request (a 206 is not cached by URLCache, and the header fetch
            // must see the live ETag), so with the archive as the only source
            // this cache holds nothing. The parsed result is what is cached,
            // by PreparedTileDiskCaching.
            configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                              diskCapacity: 1024 * 1024 * 1024)
            configuration.requestCachePolicy = .useProtocolCachePolicy
        } else {
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        }
        return configuration
    }

    func download(tile: Tile) async -> Data? {
        let result = await downloadResult(tile: tile)
        if case let .success(data, _) = result {
            return data
        }
        return nil
    }

    func downloadResult(tile: Tile) async -> DownloadResult {
        do {
            switch try await archive.tileBytes(z: tile.z, x: tile.x, y: tile.y) {
            case let .tile(data, etag):
                guard data.isEmpty == false else {
                    #if DEBUG
                    print("Tile archive holds an empty tile \(tile)")
                    #endif
                    return .failure(.emptyBody)
                }
                return .success(data, etag: etag)
            case .missing:
                // Absent from the directory: known empty, the same news a
                // 404 used to carry, with the same long cooldown.
                return .failure(.notFound)
            case .outsideZoomRange:
                // The coverage setting asks deeper (or shallower) than the
                // archive goes. Known empty for the loader, and worth one
                // line for the developer, because the fix is a setting.
                if TileNoticeThrottle.archiveDepth.shouldLog() {
                    Self.logger.warning("ImmersiveMap: tile \(tile.z, privacy: .public)/\(tile.x, privacy: .public)/\(tile.y, privacy: .public) is outside the zoom range of the tile archive, so it renders empty. Set tileMaximumZoomLevel(_:) to the archive's depth.")
                }
                return .failure(.notFound)
            }
        } catch let failure as PMTilesArchiveClient.Failure {
            return .failure(Self.downloadFailure(for: failure, tile: tile, archiveURL: archive.archiveURL))
        } catch {
            #if DEBUG
            print("Downloading tile failed \(tile): \(error)")
            #endif
            return .failure(.network)
        }
    }

    /// The archive client's failures in the loader's vocabulary. A status on
    /// the archive URL is mapped like the same status on a tile URL was,
    /// except 404 and 410, which are the archive going missing rather than a
    /// tile the archive does not have.
    private static func downloadFailure(for failure: PMTilesArchiveClient.Failure,
                                        tile: Tile,
                                        archiveURL: URL) -> DownloadFailure {
        switch failure {
        case let .http(statusCode, body, retryAfter):
            #if DEBUG
            print("Tile archive request failed with status \(statusCode) \(tile)")
            #endif
            switch statusCode {
            case 401, 403:
                // Warned about outside DEBUG on purpose, like the rate
                // limit below: a revoked or mistyped key is found in the
                // field, and a silent map full of holes gives no clue.
                if TileNoticeThrottle.authorization.shouldLog() {
                    let message = authorizationFailureMessage(statusCode: statusCode,
                                                              url: archiveURL,
                                                              responseBody: body)
                    logger.warning("\(message, privacy: .public)")
                }
                return statusCode == 401 ? .unauthorized : .forbidden
            case 404, 410:
                if TileNoticeThrottle.archiveUnreadable.shouldLog() {
                    logger.warning("ImmersiveMap: the tile archive at \(archiveURL.absoluteString, privacy: .public) answered HTTP \(statusCode, privacy: .public). Tiles will be missing until the archive is reachable at that URL.")
                }
                return .archiveUnavailable
            case 429:
                // Warned about outside DEBUG on purpose: running out of tile
                // quota is not a bug to catch at the desk, it is a thing that
                // starts happening once real users arrive. os.Logger keeps it
                // out of stdout, so it costs a release build nothing.
                if TileNoticeThrottle.rateLimit.shouldLog() {
                    let message = rateLimitMessage(responseBody: body)
                    logger.warning("\(message, privacy: .public)")
                }
                return .rateLimited(retryAfter: retryAfter)
            case 500...599:
                return .server(statusCode: statusCode)
            default:
                return .client(statusCode: statusCode)
            }
        case let .archiveUnreadable(reason):
            #if DEBUG
            print("Tile archive unreadable \(tile): \(reason)")
            #endif
            if TileNoticeThrottle.archiveUnreadable.shouldLog() {
                logger.warning("ImmersiveMap: the tile archive at \(archiveURL.absoluteString, privacy: .public) could not be read (\(reason, privacy: .public)). Check that the URL points at a PMTiles v3 archive of gzip or uncompressed MVT tiles.")
            }
            return .archiveUnavailable
        case .nonHTTPResponse:
            #if DEBUG
            print("Tile archive request returned non-HTTP response \(tile)")
            #endif
            return .nonHTTPResponse
        case let .network(description):
            #if DEBUG
            print("Downloading tile failed \(tile): \(description)")
            #endif
            return .network
        }
    }
}

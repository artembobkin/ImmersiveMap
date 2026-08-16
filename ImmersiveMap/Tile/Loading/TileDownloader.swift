// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import os

/// Throttles the rate-limit warning to one line per interval, process wide.
///
/// A blocked viewport is about thirty tiles refused at once, and every one of
/// them carries the same news. Logged per tile it is noise the developer
/// scrolls past; logged once it is the answer to "why is my map full of holes".
/// Process wide rather than per downloader because the quota belongs to the
/// app's key, not to whichever downloader happened to notice first.
/// `@unchecked Sendable` because the lock is the synchronisation the compiler
/// cannot see: the state is private and every path to it goes through `lock`.
final class TileRateLimitNotice: @unchecked Sendable {
    static let shared = TileRateLimitNotice()
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

/// `@unchecked Sendable`: every stored property is immutable after `init`
/// except `tileJSONTemplateTask`, which is written once in `init` and read
/// only in `deinit`; `URLSession` and the URL providers are safe to share.
/// The loader and the offline region downloader both call `downloadResult`
/// from many concurrent tasks.
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
    }

    enum DownloadResult: Equatable, Sendable {
        case success(Data, etag: String?)
        case failure(DownloadFailure)
    }

    private let mapTileDownloader: GetMapTileDownloadUrl
    private let customHeaders: [String: String]
    private let session: URLSession
    // Retains the TileJSON discovery task so it can be cancelled on deinit; nil
    // when no TileJSON endpoint is configured (a bare tile base URL).
    private var tileJSONTemplateTask: Task<Void, Never>?

    init(config: ImmersiveMapSettings) {
        let configuration = Self.makeSessionConfiguration(urlCacheEnabled: config.tiles.cache.urlCacheEnabled,
                                                          maxConcurrentFetches: config.tiles.network.maxConcurrentFetches)
        if config.tiles.cache.clearDiskCachesOnLaunch {
            configuration.urlCache?.removeAllCachedResponses()
        }
        let network = config.tiles.network
        customHeaders = network.tileRequestHeaders
        let baseProvider = BackendTileURLProvider(baseURL: network.tileBaseURL)
        if let template = network.tileURLTemplate {
            // An explicit template is complete configuration: no discovery
            // request, no appended path, the query string as written.
            self.mapTileDownloader = TemplateTileURLProvider(template: template,
                                                             fallback: baseProvider)
        } else if let tileJSONURL = network.tileJSONURL {
            // Prefer the versioned, immutable TileJSON template (…/v/<version>/…),
            // which the CDN caches for a year. Until the document resolves - and
            // permanently if it never does - tiles come from the legacy base path,
            // so rendering is never blocked on the discovery request.
            let store = TileJSONTemplateStore()
            self.mapTileDownloader = TileJSONTileURLProvider(fallback: baseProvider,
                                                             store: store)
            let loader = TileJSONTemplateLoader()
            tileJSONTemplateTask = Task(priority: .utility) {
                guard let template = try? await loader.loadTemplate(from: tileJSONURL),
                      Task.isCancelled == false else {
                    return
                }
                store.update(template)
            }
        } else {
            self.mapTileDownloader = baseProvider
        }
        self.session = URLSession(configuration: configuration)
    }

    init(mapTileDownloader: GetMapTileDownloadUrl,
         session: URLSession,
         customHeaders: [String: String] = [:]) {
        self.mapTileDownloader = mapTileDownloader
        self.session = session
        self.customHeaders = customHeaders
    }

    deinit {
        tileJSONTemplateTask?.cancel()
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
        // and the disk-first path keeps serving previous content meanwhile.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        if urlCacheEnabled {
            // Raw tiles are cached by URLSession's HTTP cache (URLCache): the single
            // raw-tile cache layer. It revalidates against the tile server's ETag /
            // Cache-Control, so a tile whose server content changed is refreshed
            // instead of served stale. The parsed/tessellated result is cached
            // separately by PreparedTileDiskCaching. Sized generously for map tiles.
            configuration.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                              diskCapacity: 1024 * 1024 * 1024)
            configuration.requestCachePolicy = .useProtocolCachePolicy
        } else {
            // Raw HTTP tile caching disabled: every download hits the network.
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
        let zoom = tile.z
        let x = tile.x
        let y = tile.y
        
        let tileURL = mapTileDownloader.get(tileX: x, tileY: y, tileZ: zoom)
        var request = URLRequest(url: tileURL)
        // Tile CDNs widely speak HTTP/3; this lets the very first connection
        // try QUIC instead of waiting for an Alt-Svc upgrade, and URLSession
        // falls back to HTTP/2 or 1.1 transparently where it is unsupported.
        request.assumesHTTP3Capable = true
        // Header-based credentials travel here: the tile source's custom
        // headers are set on every request, `Authorization` included.
        for (field, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                #if DEBUG
                print("Tile download returned non-HTTP response \(tile)")
                #endif
                return .failure(.nonHTTPResponse)
            }
            let statusCode = httpResponse.statusCode
            guard (200...299).contains(statusCode) else {
                #if DEBUG
                print("Tile download failed with status \(statusCode) \(tile)")
                #endif
                switch statusCode {
                case 401:
                    return .failure(.unauthorized)
                case 403:
                    return .failure(.forbidden)
                case 404:
                    return .failure(.notFound)
                case 410:
                    return .failure(.gone)
                case 429:
                    let retryAfterHeader = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    let retryAfter = retryAfterHeader.flatMap(TimeInterval.init)
                    // Warned about outside DEBUG on purpose: running out of tile
                    // quota is not a bug to catch at the desk, it is a thing that
                    // starts happening once real users arrive. os.Logger keeps it
                    // out of stdout, so it costs a release build nothing.
                    if TileRateLimitNotice.shared.shouldLog() {
                        let message = Self.rateLimitMessage(responseBody: data)
                        Self.logger.warning("\(message, privacy: .public)")
                    }
                    return .failure(.rateLimited(retryAfter: retryAfter))
                case 500...599:
                    return .failure(.server(statusCode: statusCode))
                default:
                    return .failure(.client(statusCode: statusCode))
                }
            }
            guard data.isEmpty == false else {
                #if DEBUG
                print("Tile download returned empty body \(tile)")
                #endif
                return .failure(.emptyBody)
            }

            // Normalize a missing or empty ETag to nil so it is never confused with a
            // real value; the prepared cache treats nil as "cannot prove freshness".
            let rawETag = httpResponse.value(forHTTPHeaderField: "Etag")
            let etag = (rawETag?.isEmpty == false) ? rawETag : nil
            return .success(data, etag: etag)
        } catch {
            #if DEBUG
            print("Downloading tile failed \(tile): \(error)")
            #endif
            return .failure(.network)
        }
    }
}

// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

class TileDownloader {
    enum DownloadFailure: Equatable {
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

    enum DownloadResult: Equatable {
        case success(Data, etag: String?)
        case failure(DownloadFailure)
    }

    private let mapTileDownloader: GetMapTileDownloadUrl
    private let authorizationToken: String?
    private let authorizationMode: ImmersiveMapSettings.TileSettings.NetworkSettings.AuthorizationMode
    private let session: URLSession

    init(config: ImmersiveMapSettings) {
        let configuration = Self.makeSessionConfiguration(urlCacheEnabled: config.tiles.cache.urlCacheEnabled)
        if config.tiles.cache.clearDiskCachesOnLaunch {
            configuration.urlCache?.removeAllCachedResponses()
        }
        let network = config.tiles.network
        authorizationToken = network.authorizationToken
        authorizationMode = network.authorizationMode
        self.mapTileDownloader = BackendTileURLProvider(
            baseURL: network.tileBaseURL,
            queryItemsProvider: Self.queryItemsProvider(token: network.authorizationToken,
                                                        mode: network.authorizationMode)
        )
        self.session = URLSession(configuration: configuration)
    }

    init(mapTileDownloader: GetMapTileDownloadUrl, session: URLSession, authorizationToken: String?) {
        self.mapTileDownloader = mapTileDownloader
        self.session = session
        self.authorizationToken = authorizationToken
        self.authorizationMode = .bearerHeader
    }

    static func makeSessionConfiguration(urlCacheEnabled: Bool = true) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
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

    private static func queryItemsProvider(token: String?,
                                           mode: ImmersiveMapSettings.TileSettings.NetworkSettings.AuthorizationMode) -> (() -> [URLQueryItem])? {
        guard let token else {
            return nil
        }

        switch mode {
        case .bearerHeader:
            return nil
        case let .accessTokenQuery(parameterName):
            return {
                [URLQueryItem(name: parameterName, value: token)]
            }
        }
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
        if let authorizationToken, authorizationMode == .bearerHeader {
            request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
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

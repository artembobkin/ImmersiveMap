// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Reads tiles out of one PMTiles archive over HTTP range requests.
///
/// The archive is one file: a header, a root directory, leaf directories and
/// the tile data. The client fetches the header and the root directory once
/// (they share the first 16 KiB), keeps the leaf directories it has needed in
/// an LRU, and answers a tile with one range request into the tile data. N
/// concurrent lookups on a cold client share one header request and one
/// request per leaf: every "get or start" hands back a `Task` that the
/// caller awaits outside the lock.
///
/// The format is the rest of this module (`PMTilesHeader`,
/// `PMTilesDirectory`, `PMTilesTileID`, `PMTilesGzip`). The client adds the
/// transport and nothing of any map engine: it hands back decompressed tile
/// bytes, and what they mean is the caller's.
///
/// `@unchecked Sendable`: the mutable state (the index, the leaf cache and
/// the in-flight tasks) is private and every path to it goes through
/// `stateQueue`. Everything else is immutable after `init`.
package final class PMTilesArchiveClient: @unchecked Sendable {
    /// What one range request came back with.
    package struct RangeResponse: Sendable {
        package var statusCode: Int
        package var headers: [String: String]
        package var body: Data

        package init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }

        package func header(_ name: String) -> String? {
            let wanted = name.lowercased()
            return headers.first { $0.key.lowercased() == wanted }?.value
        }
    }

    package typealias RangeFetcher = @Sendable (_ range: Range<UInt64>, _ ifMatchETag: String?) async throws -> RangeResponse

    struct Index: Sendable {
        let header: PMTilesHeader
        let root: PMTilesDirectory
        let etag: String?
    }

    package enum Outcome: Sendable, Equatable {
        case tile(Data, etag: String?)
        case missing
        case outsideZoomRange
    }

    package enum Failure: Error, Equatable {
        case http(statusCode: Int, body: Data, retryAfter: TimeInterval?)
        /// The session gave no HTTP response. The text is the transport's
        /// own description, for the log and the live-archive diagnostic.
        case network(String)
        case nonHTTPResponse
        case archiveUnreadable(String)
    }

    /// Leaf directories held in memory. An entry costs about 24 bytes, so
    /// this is hundreds of thousands of entries, a planet's worth of leaves
    /// for one viewport's neighbourhood.
    package static let leafCacheCostLimit = 16 * 1024 * 1024

    package let archiveURL: URL
    private let requestHeaders: [String: String]
    private let fetchRange: RangeFetcher

    private let stateQueue = DispatchQueue(label: "PMTiles.PMTilesArchiveClient.state")
    private var index: Index?
    private var indexTask: Task<Index, Error>?
    private var leafDirectories = PMTilesDirectoryCache(costLimit: PMTilesArchiveClient.leafCacheCostLimit)
    private var leafTasks: [UInt64: Task<PMTilesDirectory, Error>] = [:]

    package init(archiveURL: URL, requestHeaders: [String: String], session: URLSession) {
        self.archiveURL = archiveURL
        self.requestHeaders = requestHeaders
        self.fetchRange = Self.makeURLSessionFetcher(archiveURL: archiveURL,
                                                     requestHeaders: requestHeaders,
                                                     session: session)
    }

    /// The test seam: a fetcher in place of the session. Not a protocol, a
    /// function, so the tile source stays one URL plus headers.
    package init(archiveURL: URL, requestHeaders: [String: String], fetchRange: @escaping RangeFetcher) {
        self.archiveURL = archiveURL
        self.requestHeaders = requestHeaders
        self.fetchRange = fetchRange
    }

    // MARK: - Lookup

    /// The bytes of tile z/x/y, decompressed, or the reason there are none.
    package func tileBytes(z: Int, x: Int, y: Int) async throws -> Outcome {
        do {
            return try await lookup(z: z, x: x, y: y)
        } catch Failure.archiveUnreadable(let reason) where reason == Self.archiveReplacedReason {
            // The archive was replaced under us: the index is stale. Reload
            // once, then give up for this tile and let the caller decide
            // when to ask again.
            resetIndex()
            return try await lookup(z: z, x: x, y: y)
        }
    }

    private static let archiveReplacedReason = "archive replaced"

    private func lookup(z: Int, x: Int, y: Int) async throws -> Outcome {
        let index = try await loadIndex()
        let header = index.header
        guard z >= Int(header.minZoom), z <= Int(header.maxZoom) else {
            return .outsideZoomRange
        }
        guard let tileID = PMTilesTileID.id(z: z, x: x, y: y) else {
            return .missing
        }

        var directory = index.root
        var depth = 0
        while true {
            switch directory.lookup(tileID: tileID) {
            case .missing:
                return .missing
            case .leaf(let entry):
                depth += 1
                guard depth <= 3 else {
                    throw Failure.archiveUnreadable("leaf directories nested deeper than three levels")
                }
                directory = try await loadLeaf(entry: entry, index: index)
            case .tile(let entry):
                let response = try await fetch(range: header.tileDataRange(for: entry),
                                               expectedETag: index.etag)
                let bytes: Data
                do {
                    bytes = try PMTilesGzip.decompress(response.body, compression: header.tileCompression)
                } catch {
                    throw Failure.archiveUnreadable("tile \(z)/\(x)/\(y): \(error)")
                }
                return .tile(bytes, etag: "\(index.etag ?? "-")/\(tileID)")
            }
        }
    }

    // MARK: - Index and leaves

    private func loadIndex() async throws -> Index {
        let task: Task<Index, Error> = stateQueue.sync {
            if let index {
                return Task { index }
            }
            if let indexTask {
                return indexTask
            }
            let started = Task<Index, Error> { [self] in
                try await self.fetchIndex()
            }
            indexTask = started
            return started
        }
        do {
            let loaded = try await task.value
            stateQueue.sync {
                if index == nil {
                    index = loaded
                }
                indexTask = nil
            }
            return loaded
        } catch {
            stateQueue.sync {
                if indexTask == task {
                    indexTask = nil
                }
            }
            throw error
        }
    }

    private func fetchIndex() async throws -> Index {
        let response = try await fetch(range: 0..<UInt64(PMTilesHeader.initialFetchByteCount),
                                       expectedETag: nil)
        let header: PMTilesHeader
        do {
            header = try PMTilesHeader(parsing: response.body)
        } catch {
            throw Failure.archiveUnreadable("header: \(error)")
        }
        let rootRange = header.rootDirectoryRange
        let rootBytes: Data
        if rootRange.upperBound <= UInt64(response.body.count) {
            rootBytes = response.body.subdata(in: Int(rootRange.lowerBound)..<Int(rootRange.upperBound))
        } else {
            // A root directory past the first 16 KiB breaks the specification's
            // promise, but the archive is still readable with one more request.
            rootBytes = try await fetch(range: rootRange, expectedETag: response.etag).body
        }
        let root: PMTilesDirectory
        do {
            root = try PMTilesDirectory(decoding: try PMTilesGzip.decompress(rootBytes,
                                                                             compression: header.internalCompression))
        } catch {
            throw Failure.archiveUnreadable("root directory: \(error)")
        }
        return Index(header: header, root: root, etag: response.etag)
    }

    private func loadLeaf(entry: PMTilesEntry, index: Index) async throws -> PMTilesDirectory {
        let key = entry.offset
        let task: Task<PMTilesDirectory, Error> = stateQueue.sync {
            if let cached = leafDirectories.directory(atOffset: key) {
                return Task { cached }
            }
            if let running = leafTasks[key] {
                return running
            }
            let started = Task<PMTilesDirectory, Error> { [self] in
                let response = try await self.fetch(range: index.header.leafDirectoryRange(for: entry),
                                                    expectedETag: index.etag)
                do {
                    let bytes = try PMTilesGzip.decompress(response.body,
                                                           compression: index.header.internalCompression)
                    return try PMTilesDirectory(decoding: bytes)
                } catch {
                    throw Failure.archiveUnreadable("leaf directory at \(entry.offset): \(error)")
                }
            }
            leafTasks[key] = started
            return started
        }
        defer {
            stateQueue.sync {
                if leafTasks[key] == task {
                    leafTasks[key] = nil
                }
            }
        }
        let directory = try await task.value
        stateQueue.sync {
            leafDirectories.insert(directory, atOffset: key, cost: directory.entries.count * 24)
        }
        return directory
    }

    private func resetIndex() {
        stateQueue.sync {
            index = nil
            indexTask = nil
            leafDirectories.removeAll()
            leafTasks.removeAll()
        }
    }

    // MARK: - Ranges

    private struct RangeBytes {
        let body: Data
        let etag: String?
    }

    /// One range request, checked: a 206 whose body is the range, a 200 the
    /// server answered with the whole file (sliced), or the signal that the
    /// archive changed (412, 416, or an ETag other than the one the index
    /// was read under).
    private func fetch(range: Range<UInt64>, expectedETag: String?) async throws -> RangeBytes {
        let response = try await fetchRange(range, expectedETag)
        let etag = Self.normalizedETag(response.header("ETag"))
        switch response.statusCode {
        case 206:
            if let expectedETag, let etag, etag != expectedETag {
                throw Failure.archiveUnreadable(Self.archiveReplacedReason)
            }
            if let contentRange = response.header("Content-Range"),
               let start = Self.rangeStart(fromContentRange: contentRange),
               start != range.lowerBound {
                throw Failure.archiveUnreadable("range request answered from byte \(start), asked for \(range.lowerBound)")
            }
            let wanted = Int(range.upperBound - range.lowerBound)
            // The initial fetch may reach past a small archive's end, so a
            // short body is fine there. A short tile or leaf is not.
            return RangeBytes(body: response.body.count > wanted ? response.body.prefix(wanted) : response.body,
                              etag: etag)
        case 200:
            if let expectedETag, let etag, etag != expectedETag {
                throw Failure.archiveUnreadable(Self.archiveReplacedReason)
            }
            guard UInt64(response.body.count) >= range.lowerBound else {
                throw Failure.archiveUnreadable("range request ignored and the body is shorter than the range")
            }
            let end = min(UInt64(response.body.count), range.upperBound)
            return RangeBytes(body: response.body.subdata(in: Int(range.lowerBound)..<Int(end)), etag: etag)
        case 412, 416:
            throw Failure.archiveUnreadable(Self.archiveReplacedReason)
        default:
            let retryAfter = response.header("Retry-After").flatMap(TimeInterval.init)
            throw Failure.http(statusCode: response.statusCode, body: response.body, retryAfter: retryAfter)
        }
    }

    /// A weak validator (`W/"..."`) proves nothing about the bytes, so it
    /// is not an ETag for the purpose of `If-Match`.
    package static func normalizedETag(_ raw: String?) -> String? {
        guard let raw, raw.isEmpty == false, raw.hasPrefix("W/") == false else {
            return nil
        }
        return raw
    }

    package static func rangeStart(fromContentRange value: String) -> UInt64? {
        // "bytes 0-16383/123456"
        guard let bytesRange = value.split(separator: " ").last,
              let startText = bytesRange.split(separator: "-").first else {
            return nil
        }
        return UInt64(startText)
    }

    private static func makeURLSessionFetcher(archiveURL: URL,
                                              requestHeaders: [String: String],
                                              session: URLSession) -> RangeFetcher {
        { range, ifMatchETag in
            var request = URLRequest(url: archiveURL)
            request.assumesHTTP3Capable = true
            // Range responses are not cached by URLCache, and the header
            // fetch must see the live ETag, so the cache is bypassed.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            for (field, value) in requestHeaders {
                request.setValue(value, forHTTPHeaderField: field)
            }
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            if let ifMatchETag {
                request.setValue(ifMatchETag, forHTTPHeaderField: "If-Match")
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw Failure.network(error.localizedDescription)
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw Failure.nonHTTPResponse
            }
            var headers: [String: String] = [:]
            for (name, value) in httpResponse.allHeaderFields {
                if let name = name as? String, let value = value as? String {
                    headers[name] = value
                }
            }
            return RangeResponse(statusCode: httpResponse.statusCode, headers: headers, body: data)
        }
    }
}

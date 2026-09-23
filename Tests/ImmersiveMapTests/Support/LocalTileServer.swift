// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Network

/// A minimal HTTP server on loopback that serves one resource by byte range,
/// the way a static host serves a PMTiles archive.
///
/// Some cases need a map that actually has tiles on it, and the only way to
/// get one through a public entry point (`ImmersiveMapStillRecorder` builds
/// its own engine, so a test cannot reach its tile store) used to be letting
/// the request go to the real tile service. That makes the case depend on the
/// network, on the service's rate limiting, and on how fast tiles arrive
/// within the capture's settle window: it is exactly why the scene-model
/// capture case failed on CI while passing locally.
///
/// The bytes come from `PMTilesArchiveWriter` over `VectorTileFixture`, so the
/// archive is the same on every run and on every machine, and the request
/// travels the real path (range request, header, directory, tile, parse,
/// materialize) rather than being injected behind it.
///
/// Tests do not build one of these directly: ``FixtureTileService`` owns the
/// one the suite renders from. `PMTilesArchiveClientTests` builds its own to
/// script the replaced-archive and ignored-range answers.
final class LocalTileServer: @unchecked Sendable {
    /// The resource at a path: its bytes and the validator they answer with.
    /// A router returning nil makes the server reply 404.
    struct Resource: Sendable {
        var body: Data
        var etag: String
        var contentType: String
        /// A host that ignores the `Range` header and answers the whole file
        /// with 200. The client has to cope, so the server can be told to be
        /// one.
        var ignoresRanges = false

        static func archive(_ body: Data, etag: String = "\"immersive-map-test-fixture\"") -> Resource {
            Resource(body: body, etag: etag, contentType: "application/octet-stream")
        }
    }

    /// One parsed request, as the router sees it.
    struct Request: Sendable {
        var path: String
        var headers: [String: String]

        func header(_ name: String) -> String? {
            let wanted = name.lowercased()
            return headers.first { $0.key.lowercased() == wanted }?.value
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ImmersiveMapTests.LocalTileServer")
    private let route: @Sendable (Request) -> Resource?

    /// - Parameter route: called with the request (path such as
    ///   `/planet.pmtiles`, and the headers) on the server's own serial
    ///   queue, so it sees one request at a time, but never on the caller's
    ///   thread.
    init(route: @escaping @Sendable (Request) -> Resource?) throws {
        self.route = route

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Bound to loopback, and to a port the system picks. Loopback because
        // a fixture archive has no business being reachable from whatever
        // network the machine is on, and because binding every interface is
        // what makes macOS ask the developer whether to allow incoming
        // connections. Port zero because parallel test runs and a developer's
        // own servers must never collide.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)

        let started = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            // `.waiting` is where a bind failure actually lands (measured:
            // `waiting(POSIXErrorCode(49): Can't assign requested address)`),
            // and it does not resolve itself for a listener that cannot have
            // the endpoint it asked for. Waiting the full timeout on it stalls
            // the caller, which is a main-thread test, for five seconds and
            // then reports the same thing.
            case .ready, .waiting, .failed, .cancelled:
                started.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [route, queue] connection in
            connection.start(queue: queue)
            Self.readRequest(on: connection, received: Data(), route: route)
        }
        listener.start(queue: queue)
        _ = started.wait(timeout: .now() + 5)
    }

    /// Root of the served namespace; nil when the listener never came up.
    ///
    /// A listener that failed to bind reports port 0 rather than nil
    /// (measured), so the obvious `listener.port != nil` test is not the one
    /// to make: it would hand out `http://127.0.0.1:0`, which refuses every
    /// connection exactly like the dead port. Nothing would reach the network,
    /// but every rendering case would go quietly tile-less and say so in
    /// whatever terms its own assertion is phrased in, rather than here.
    var baseURL: URL? {
        guard let port = listener.port?.rawValue, port != 0 else {
            return nil
        }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// The archive URL to point the tile network settings at.
    var archiveURL: URL? {
        baseURL?.appendingPathComponent(String(Self.archivePath.dropFirst()))
    }

    /// Where the fixture archive lives under the base URL.
    static let archivePath = "/planet.pmtiles"

    deinit {
        listener.cancel()
    }

    /// Reads until the header block is complete, then answers exactly once.
    ///
    /// One `receive` is not enough. TCP may split even a short GET, and an
    /// earlier version answered whatever had arrived by then: a truncated
    /// path matched no route and became a 404. A 404 on the archive is the
    /// most expensive wrong answer this server can give, because the loader
    /// reads it as the archive being gone and backs off, which inside a test
    /// process can empty the map for the rest of the run, silently. That is
    /// the flake this whole fixture service exists to remove.
    private static func readRequest(on connection: NWConnection,
                                    received: Data,
                                    route: @escaping @Sendable (Request) -> Resource?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumRequestBytes) { content, _, isComplete, error in
            var request = received
            if let content {
                request.append(content)
            }
            let headersComplete = request.range(of: Data("\r\n\r\n".utf8)) != nil
            if headersComplete == false, isComplete == false, error == nil,
               request.count < maximumRequestBytes {
                readRequest(on: connection, received: request, route: route)
                return
            }
            // A request that never arrived in full gets a 400 rather than a
            // 404: the loader retries a client error within a second and
            // backs off an archive that is gone.
            let response = parsedRequest(in: request).map { parsed in
                httpResponse(for: route(parsed), request: parsed)
            } ?? httpResponse(status: "400 Bad Request")
            connection.send(content: response,
                            completion: .contentProcessed { _ in
                                connection.cancel()
                            })
        }
    }

    /// The request line and headers out of a complete header block, query
    /// string dropped from the path. Nil when the request line is not all
    /// there, so a partial read cannot be mistaken for a request for `/`.
    private static func parsedRequest(in data: Data) -> Request? {
        let head = String(decoding: data.prefix(maximumRequestBytes), as: UTF8.self)
        guard let lineEnd = head.range(of: "\r\n") else {
            return nil
        }
        // Method, target and version: a request line that is all there has
        // three fields, and anything shorter is a read that stopped early.
        let fields = head[head.startIndex..<lineEnd.lowerBound].split(separator: " ")
        guard fields.count == 3 else {
            return nil
        }
        // `prefix`, not `split`: splitting "?" on "?" drops both empty halves
        // and leaves an empty array, and subscripting that traps and takes the
        // whole test process with it.
        let path = String(fields[1].prefix { $0 != "?" })

        var headers: [String: String] = [:]
        let headerBlock = head[lineEnd.upperBound...]
        let blockEnd = headerBlock.range(of: "\r\n\r\n")?.lowerBound ?? headerBlock.endIndex
        for line in headerBlock[headerBlock.startIndex..<blockEnd].split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return Request(path: path, headers: headers)
    }

    private static let maximumRequestBytes = 64 * 1024

    /// A bodiless answer, for the paths that carry nothing and for a request
    /// that never arrived in full.
    private static func httpResponse(status: String, extraHeaders: String = "") -> Data {
        let header = """
            HTTP/1.1 \(status)\r
            Content-Length: 0\r
            \(extraHeaders)Cache-Control: no-store\r
            Connection: close\r
            \r\n
            """
        return Data(header.utf8)
    }

    /// The answer a static host gives: 206 for a satisfiable range, 416 for a
    /// range that starts past the end, 412 when `If-Match` names another
    /// ETag, and 200 with the whole file when no range was asked for (or the
    /// resource is told to ignore ranges).
    private static func httpResponse(for resource: Resource?, request: Request) -> Data {
        guard let resource else {
            return httpResponse(status: "404 Not Found")
        }
        let total = resource.body.count
        if let ifMatch = request.header("If-Match"), ifMatch != resource.etag {
            return httpResponse(status: "412 Precondition Failed", extraHeaders: "ETag: \(resource.etag)\r\n")
        }
        let range = resource.ignoresRanges ? nil : request.header("Range").flatMap { byteRange($0, total: total) }
        if request.header("Range") != nil, resource.ignoresRanges == false, range == nil {
            return httpResponse(status: "416 Range Not Satisfiable",
                                extraHeaders: "Content-Range: bytes */\(total)\r\nETag: \(resource.etag)\r\n")
        }
        let status: String
        let body: Data
        var rangeHeader = ""
        if let range {
            status = "206 Partial Content"
            body = resource.body.subdata(in: range)
            rangeHeader = "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)\r\n"
        } else {
            status = "200 OK"
            body = resource.body
        }
        let header = """
            HTTP/1.1 \(status)\r
            Content-Type: \(resource.contentType)\r
            Content-Length: \(body.count)\r
            \(rangeHeader)Accept-Ranges: bytes\r
            ETag: \(resource.etag)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r\n
            """
        var bytes = Data(header.utf8)
        bytes.append(body)
        return bytes
    }

    /// `bytes=a-b` clamped to the resource, or nil when it starts past the
    /// end (which is what 416 means). A suffix range (`bytes=-n`) and an open
    /// end (`bytes=a-`) are both understood, since a real host does.
    private static func byteRange(_ value: String, total: Int) -> Range<Int>? {
        guard value.hasPrefix("bytes=") else {
            return nil
        }
        let spec = value.dropFirst("bytes=".count)
        guard let dash = spec.firstIndex(of: "-") else {
            return nil
        }
        let startText = spec[spec.startIndex..<dash]
        let endText = spec[spec.index(after: dash)...]
        if startText.isEmpty {
            guard let suffix = Int(endText), suffix > 0 else {
                return nil
            }
            return max(0, total - suffix)..<total
        }
        guard let start = Int(startText), start < total else {
            return nil
        }
        let end = Int(endText).map { min($0 + 1, total) } ?? total
        guard end > start else {
            return nil
        }
        return start..<end
    }
}

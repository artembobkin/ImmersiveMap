// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Network

/// A minimal HTTP server on loopback that answers whatever a router hands it.
///
/// Some cases need a map that actually has tiles on it, and the only way to
/// get one through a public entry point (`ImmersiveMapStillRecorder` builds
/// its own engine, so a test cannot reach its tile store) used to be letting
/// the request go to the real tile service. That makes the case depend on the
/// network, on the service's rate limiting, and on how fast tiles arrive
/// within the capture's settle window: it is exactly why the scene-model
/// capture case failed on CI while passing locally.
///
/// The bytes come from `VectorTileFixture`, so the tile is the same on every
/// run and on every machine, and the request travels the real path (URL,
/// download, parse, materialize) rather than being injected behind it.
///
/// Tests do not build one of these directly: ``FixtureTileService`` owns the
/// one the suite renders from.
final class LocalTileServer: @unchecked Sendable {
    /// One answer: the bytes and what they are. A router returning nil makes
    /// the server reply 404, which the tile loader reads as "this tile has
    /// nothing to render" rather than as a transport failure.
    struct Response {
        let contentType: String
        let body: Data

        static func protobuf(_ body: Data) -> Response {
            Response(contentType: "application/x-protobuf", body: body)
        }

        static func json(_ body: Data) -> Response {
            Response(contentType: "application/json", body: body)
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ImmersiveMapTests.LocalTileServer")
    private let route: @Sendable (String) -> Response?

    /// - Parameter route: called with the request path (`/tiles/3/4/5.mvt`),
    ///   on the server's own queue and possibly concurrently, so it must not
    ///   capture mutable state.
    init(route: @escaping @Sendable (String) -> Response?) throws {
        self.route = route

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Port 0 asks the system for a free one, so parallel test runs and a
        // developer's own servers never collide.
        listener = try NWListener(using: parameters, on: .any)

        let started = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                started.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [route, queue] connection in
            connection.start(queue: queue)
            // Reading the request keeps the client from seeing a reset before
            // its write completes, and is how the path is known at all. A tile
            // request is a bare GET, so it arrives in one segment.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, _, _ in
                let path = content.flatMap(Self.requestPath(in:)) ?? "/"
                let response = Self.httpResponse(for: route(path))
                connection.send(content: response,
                                completion: .contentProcessed { _ in
                                    connection.cancel()
                                })
            }
        }
        listener.start(queue: queue)
        _ = started.wait(timeout: .now() + 5)
    }

    /// Root of the served namespace; nil while the listener has no port, which
    /// means it never came up.
    var baseURL: URL? {
        guard let port = listener.port?.rawValue else {
            return nil
        }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// The base URL to hand to `ImmersiveMapTilesProvider`. The provider
    /// appends `/{z}/{x}/{y}.mvt` and derives its TileJSON endpoint by
    /// swapping the last component for `tiles.json`.
    var tileBaseURL: URL? {
        baseURL?.appendingPathComponent("tiles")
    }

    deinit {
        listener.cancel()
    }

    /// The path out of a request line such as `GET /tiles/3/4/5.mvt HTTP/1.1`,
    /// query string dropped.
    private static func requestPath(in data: Data) -> String? {
        guard let requestLine = String(decoding: data.prefix(8 * 1024), as: UTF8.self)
            .split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else {
            return nil
        }
        return String(fields[1].split(separator: "?", maxSplits: 1)[0])
    }

    private static func httpResponse(for response: Response?) -> Data {
        guard let response else {
            let notFound = """
                HTTP/1.1 404 Not Found\r
                Content-Length: 0\r
                Cache-Control: no-store\r
                Connection: close\r
                \r\n
                """
            return Data(notFound.utf8)
        }
        let header = """
            HTTP/1.1 200 OK\r
            Content-Type: \(response.contentType)\r
            Content-Length: \(response.body.count)\r
            ETag: "immersive-map-test-fixture"\r
            Cache-Control: no-store\r
            Connection: close\r
            \r\n
            """
        var bytes = Data(header.utf8)
        bytes.append(response.body)
        return bytes
    }
}

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

    /// - Parameter route: called with the request path (`/tiles/3/4/5.mvt`) on
    ///   the server's own serial queue, so it sees one request at a time, but
    ///   never on the caller's thread.
    init(route: @escaping @Sendable (String) -> Response?) throws {
        self.route = route

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Bound to loopback, and to a port the system picks. Loopback because
        // a fixture tile has no business being reachable from whatever network
        // the machine is on, and because binding every interface is what makes
        // macOS ask the developer whether to allow incoming connections. Port
        // zero because parallel test runs and a developer's own servers must
        // never collide.
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

    /// The base URL to hand to `ImmersiveMapTilesProvider`. The provider
    /// appends `/{z}/{x}/{y}.mvt` and derives its TileJSON endpoint by
    /// swapping the last component for `tiles.json`.
    var tileBaseURL: URL? {
        baseURL?.appendingPathComponent("tiles")
    }

    deinit {
        listener.cancel()
    }

    /// Reads until the header block is complete, then answers exactly once.
    ///
    /// One `receive` is not enough. TCP may split even a short GET, and an
    /// earlier version answered whatever had arrived by then: a truncated
    /// path matched no route and became a 404. A 404 is the most expensive
    /// wrong answer this server can give, because the loader reads it as
    /// "this tile has nothing to render" and puts the tile in a ten-minute
    /// cooldown (`TileRetryController.notFoundCooldown`), which inside a test
    /// process means forever. One split request would have emptied the map
    /// for the rest of the run, silently, which is the flake this whole
    /// fixture service exists to remove.
    private static func readRequest(on connection: NWConnection,
                                    received: Data,
                                    route: @escaping @Sendable (String) -> Response?) {
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
            // blacklists a not-found for ten minutes.
            let response = requestPath(in: request).map { httpResponse(for: route($0)) }
                ?? httpResponse(status: "400 Bad Request")
            connection.send(content: response,
                            completion: .contentProcessed { _ in
                                connection.cancel()
                            })
        }
    }

    /// The path out of a complete request line such as
    /// `GET /tiles/3/4/5.mvt HTTP/1.1`, query string dropped. Nil when the
    /// line is not all there, so a partial read cannot be mistaken for a
    /// request for `/`.
    private static func requestPath(in data: Data) -> String? {
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
        return String(fields[1].prefix { $0 != "?" })
    }

    private static let maximumRequestBytes = 64 * 1024

    /// A bodiless answer, for the paths that carry no tile and for a request
    /// that never arrived in full.
    private static func httpResponse(status: String) -> Data {
        let header = """
            HTTP/1.1 \(status)\r
            Content-Length: 0\r
            Cache-Control: no-store\r
            Connection: close\r
            \r\n
            """
        return Data(header.utf8)
    }

    private static func httpResponse(for response: Response?) -> Data {
        guard let response else {
            return httpResponse(status: "404 Not Found")
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

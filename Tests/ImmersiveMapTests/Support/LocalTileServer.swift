// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Network

/// Serves one vector tile, for every tile request, from localhost.
///
/// Some cases need a map that actually has tiles on it, and until now the only
/// way to get one through a public entry point (`ImmersiveMapStillRecorder`
/// builds its own engine, so a test cannot reach its tile store) was to let
/// the request go to the real tile service. That makes the case depend on the
/// network, on the service's rate limiting, and on how fast tiles arrive
/// within the capture's settle window: it is exactly why the scene-model
/// capture case failed on CI while passing locally.
///
/// The bytes come from `VectorTileFixture`, so the tile is the same on every
/// run and on every machine, and the request travels the real path (URL,
/// download, parse, materialize) rather than being injected behind it.
final class LocalTileServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ImmersiveMapTests.LocalTileServer")
    private let response: Data

    /// `tileBody` is answered for every path. The tile scheme puts z/x/y in
    /// the path, and a fixture that fills its tile looks the same wherever it
    /// lands, so no routing is needed.
    init(tileBody: Data) throws {
        let header = """
            HTTP/1.1 200 OK\r
            Content-Type: application/x-protobuf\r
            Content-Length: \(tileBody.count)\r
            ETag: "immersive-map-test-fixture"\r
            Cache-Control: no-store\r
            Connection: close\r
            \r\n
            """
        var response = Data(header.utf8)
        response.append(tileBody)
        self.response = response

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
        listener.newConnectionHandler = { [response, queue] connection in
            connection.start(queue: queue)
            // The request is read and discarded: every path gets the same
            // tile, and reading it keeps the client from seeing a reset
            // before its write completes.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                connection.send(content: response,
                                completion: .contentProcessed { _ in
                                    connection.cancel()
                                })
            }
        }
        listener.start(queue: queue)
        _ = started.wait(timeout: .now() + 5)
    }

    /// The base URL to hand to `ImmersiveMapTilesProvider`; nil while the
    /// listener has no port, which means it never came up.
    var tileBaseURL: URL? {
        guard let port = listener.port?.rawValue else {
            return nil
        }
        return URL(string: "http://127.0.0.1:\(port)/tiles")
    }

    func stop() {
        listener.cancel()
    }

    deinit {
        listener.cancel()
    }
}

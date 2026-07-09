// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Darwin
import Foundation
import XCTest

final class TileDownloaderLoggingTests: XCTestCase {
    func testDefaultSessionConfigurationAllowsTLS13() {
        let configuration = TileDownloader.makeSessionConfiguration()
        let tls13: tls_protocol_version_t = .TLSv13

        XCTAssertGreaterThanOrEqual(configuration.tlsMaximumSupportedProtocolVersion.rawValue, tls13.rawValue)
    }

    func testSuccessfulDownloadDoesNotWriteRoutineLogsToStandardOutput() async {
        let responseData = Data([0x01, 0x02, 0x03])
        SuccessfulTileURLProtocol.responseData = responseData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuccessfulTileURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let downloader = TileDownloader(
            mapTileDownloader: FixedTileURLProvider(url: URL(string: "https://example.com/tile.mvt")!),
            session: session,
            authorizationToken: nil
        )

        let output = await captureStandardOutput {
            let result = await downloader.downloadResult(tile: Tile(x: 586, y: 786, z: 11))
            XCTAssertEqual(result, .success(responseData, etag: nil))
        }

        XCTAssertEqual(output, "")
    }
}

private struct FixedTileURLProvider: GetMapTileDownloadUrl {
    let url: URL

    func get(tileX _: Int, tileY _: Int, tileZ _: Int) -> URL {
        url
    }
}

private final class SuccessfulTileURLProtocol: URLProtocol {
    static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func captureStandardOutput(_ operation: () async -> Void) async -> String {
    let originalStdout = dup(STDOUT_FILENO)
    let pipe = Pipe()

    fflush(stdout)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

    await operation()

    fflush(stdout)
    dup2(originalStdout, STDOUT_FILENO)
    close(originalStdout)

    pipe.fileHandleForWriting.closeFile()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
}

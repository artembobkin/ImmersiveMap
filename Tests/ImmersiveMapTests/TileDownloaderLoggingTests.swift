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
            session: session
        )

        let output = await captureStandardOutput {
            let result = await downloader.downloadResult(tile: Tile(x: 586, y: 786, z: 11))
            XCTAssertEqual(result, .success(responseData, etag: nil))
        }

        XCTAssertEqual(output, "")
    }

    // The tile service sends the sentence to print, because this engine is MIT
    // and ships compiled inside someone else's app: its wording is frozen the
    // day they release, the service's is a config reload away.
    func testRateLimitMessageUsesTheServersWording() {
        let body = Data(#"{"error":"rate_limited","scope":"public","message":"Get a key at https://example.test/account/"}"#.utf8)

        let message = TileDownloader.rateLimitMessage(responseBody: body)

        XCTAssertTrue(message.contains("Get a key at https://example.test/account/"), message)
        XCTAssertTrue(message.contains("rate limited"), message)
    }

    // An older tile service, or somebody else's endpoint, may answer 429 with
    // nothing useful. The reader still has to learn what went wrong.
    func testRateLimitMessageFallsBackWhenTheBodySaysNothing() {
        for body in [Data(), Data("not json".utf8), Data(#"{"error":"rate_limited"}"#.utf8)] {
            let message = TileDownloader.rateLimitMessage(responseBody: body)
            XCTAssertTrue(message.contains("429"), message)
            XCTAssertTrue(message.contains("rate limited"), message)
        }
    }

    // A blocked viewport is ~30 tiles refused at once. Thirty identical lines
    // are noise the developer scrolls past; one line is the answer.
    func testRateLimitNoticeLogsOncePerInterval() {
        let notice = TileRateLimitNotice.shared
        notice.reset()
        defer { notice.reset() }

        let start = Date()
        XCTAssertTrue(notice.shouldLog(now: start), "the first refusal of a burst must be reported")
        for i in 1...30 {
            XCTAssertFalse(notice.shouldLog(now: start.addingTimeInterval(Double(i) / 100)),
                           "tile \(i) of the same burst must stay quiet")
        }

        // Still stuck a minute later: that is worth saying again.
        let later = start.addingTimeInterval(TileRateLimitNotice.interval + 1)
        XCTAssertTrue(notice.shouldLog(now: later))
    }

    // os.Logger writes to the unified log, not to stdout, so warning in a
    // release build costs a customer's console nothing.
    func testRateLimitWarningStaysOutOfStandardOutput() async {
        TileRateLimitNotice.shared.reset()
        defer { TileRateLimitNotice.shared.reset() }

        RateLimitedTileURLProtocol.body = Data(#"{"message":"Get a key"}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitedTileURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let downloader = TileDownloader(
            mapTileDownloader: FixedTileURLProvider(url: URL(string: "https://example.com/tile.mvt")!),
            session: session
        )

        let output = await captureStandardOutput {
            let result = await downloader.downloadResult(tile: Tile(x: 586, y: 786, z: 11))
            XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 1)))
        }

        XCTAssertFalse(output.contains("Get a key"), "the advice belongs in the unified log, not stdout: \(output)")
    }
}

private final class RateLimitedTileURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "1", "X-IMT-Limit": "public"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct FixedTileURLProvider: GetMapTileDownloadUrl {
    let url: URL

    func get(tileX _: Int, tileY _: Int, tileZ _: Int) -> URL {
        url
    }
}

private final class SuccessfulTileURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()

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

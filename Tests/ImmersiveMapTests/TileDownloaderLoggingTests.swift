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
        let notice = TileNoticeThrottle.rateLimit
        notice.reset()
        defer { notice.reset() }

        let start = Date()
        XCTAssertTrue(notice.shouldLog(now: start), "the first refusal of a burst must be reported")
        for i in 1...30 {
            XCTAssertFalse(notice.shouldLog(now: start.addingTimeInterval(Double(i) / 100)),
                           "tile \(i) of the same burst must stay quiet")
        }

        // Still stuck a minute later: that is worth saying again.
        let later = start.addingTimeInterval(TileNoticeThrottle.interval + 1)
        XCTAssertTrue(notice.shouldLog(now: later))
    }

    // os.Logger writes to the unified log, not to stdout, so warning in a
    // release build costs a customer's console nothing.
    func testRateLimitWarningStaysOutOfStandardOutput() async {
        TileNoticeThrottle.rateLimit.reset()
        defer { TileNoticeThrottle.rateLimit.reset() }

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

    // A bare "401" is a number, not an instruction. The warning has to tell
    // the developer where the credential lives and where to fix it.
    func testAuthorizationMessagePointsAtTheAccountForTheHostedService() {
        let message = TileDownloader.authorizationFailureMessage(
            statusCode: 401,
            url: URL(string: "https://immersivemap.dev/tiles/0/0/0.mvt"),
            responseBody: Data())

        XCTAssertTrue(message.contains("401"), message)
        XCTAssertTrue(message.contains("unauthorized"), message)
        XCTAssertTrue(message.contains("immersivemap.dev"), message)
        XCTAssertTrue(message.contains("https://immersivemap.dev/account"), message)
    }

    // Someone else's endpoint gets the generic advice: the engine cannot know
    // where that service manages its keys, only where a credential can travel.
    func testAuthorizationMessageGivesGenericAdviceForOtherHosts() {
        let message = TileDownloader.authorizationFailureMessage(
            statusCode: 403,
            url: URL(string: "https://tiles.example.com/0/0/0.mvt?apiKey=x"),
            responseBody: Data())

        XCTAssertTrue(message.contains("403"), message)
        XCTAssertTrue(message.contains("forbidden"), message)
        XCTAssertTrue(message.contains("tiles.example.com"), message)
        XCTAssertTrue(message.contains("tileURLTemplate"), message)
        XCTAssertFalse(message.contains("immersivemap.dev/account"), message)
    }

    // The service knows more than the engine (expired vs revoked vs wrong
    // plan); its wording rides along when it sends one.
    func testAuthorizationMessageAppendsTheServersWording() {
        let body = Data(#"{"error":"unauthorized","message":"Token expired on 2026-08-01"}"#.utf8)

        let message = TileDownloader.authorizationFailureMessage(
            statusCode: 401,
            url: URL(string: "https://immersivemap.dev/tiles/0/0/0.mvt"),
            responseBody: body)

        XCTAssertTrue(message.contains("Token expired on 2026-08-01"), message)
    }

    // A rejected key and a rate limit are different news; one being reported
    // must not silence the other.
    func testAuthorizationNoticeThrottlesIndependentlyOfTheRateLimit() {
        TileNoticeThrottle.rateLimit.reset()
        TileNoticeThrottle.authorization.reset()
        defer {
            TileNoticeThrottle.rateLimit.reset()
            TileNoticeThrottle.authorization.reset()
        }

        let now = Date()
        XCTAssertTrue(TileNoticeThrottle.rateLimit.shouldLog(now: now))
        XCTAssertTrue(TileNoticeThrottle.authorization.shouldLog(now: now))
        XCTAssertFalse(TileNoticeThrottle.authorization.shouldLog(now: now.addingTimeInterval(1)))
    }

    // Same rule as the rate limit: the advice goes to the unified log, and a
    // release build's stdout stays clean.
    func testAuthorizationWarningStaysOutOfStandardOutput() async {
        TileNoticeThrottle.authorization.reset()
        defer { TileNoticeThrottle.authorization.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnauthorizedTileURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let downloader = TileDownloader(
            mapTileDownloader: FixedTileURLProvider(url: URL(string: "https://immersivemap.dev/tiles/0/0/0.mvt")!),
            session: session
        )

        let output = await captureStandardOutput {
            let result = await downloader.downloadResult(tile: Tile(x: 0, y: 0, z: 0))
            XCTAssertEqual(result, .failure(.unauthorized))
        }

        XCTAssertFalse(output.contains("immersivemap.dev/account"),
                       "the advice belongs in the unified log, not stdout: \(output)")
    }
}

private final class UnauthorizedTileURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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

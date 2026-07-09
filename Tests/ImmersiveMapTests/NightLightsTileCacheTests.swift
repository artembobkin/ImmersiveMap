// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class NightLightsTileCacheTests: XCTestCase {
    func testTileDataDoesNotDecodeMissingTilesSynchronouslyAndPrefetchLoadsInBackground() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let url = try makeJPEG(width: 2, height: 2, bytes: [0, 80, 160, 255])
        let didRequestURL = expectation(description: "prefetch requested tile URL")
        var loadCount = 0
        let cache = NightLightsTileCache { requestedTile in
            loadCount += 1
            didRequestURL.fulfill()
            return requestedTile == tile ? url : nil
        }

        XCTAssertNil(cache.tileData(for: tile))
        XCTAssertEqual(loadCount, 0)

        cache.prefetchTiles([tile])
        wait(for: [didRequestURL], timeout: 2.0)

        let data = try waitForReadyTile(tile, in: cache)
        XCTAssertEqual(data.tile, tile)
        XCTAssertEqual(data.width, 2)
        XCTAssertEqual(data.height, 2)
        XCTAssertEqual(loadCount, 1)
    }

    func testLoadsSmallGrayscaleJPEGIntoBytesAndDimensions() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let url = try makeJPEG(width: 2, height: 2, bytes: [0, 80, 160, 255])
        let cache = NightLightsTileCache { requestedTile in
            requestedTile == tile ? url : nil
        }

        cache.prefetchTiles([tile])
        let data = try waitForReadyTile(tile, in: cache)

        XCTAssertEqual(data.tile, tile)
        XCTAssertEqual(data.width, 2)
        XCTAssertEqual(data.height, 2)
        XCTAssertEqual(data.bytes.count, 8)
        XCTAssertGreaterThan(data.bytes.max() ?? 0, data.bytes.min() ?? 0)
    }

    func testMissingTileReturnsNil() {
        let cache = NightLightsTileCache { _ in nil }

        XCTAssertNil(cache.tileData(for: Tile(x: 1, y: 2, z: 3)))
    }

    func testLoadsPNGIntoInterleavedEqualCoreAndHaloBytesForGrayscale() throws {
        let tile = Tile(x: 4, y: 5, z: 6)
        let url = try makePNG(width: 3,
                              height: 2,
                              bytes: [
                                  10, 60, 110,
                                  160, 210, 250
                              ])
        let cache = NightLightsTileCache { requestedTile in
            requestedTile == tile ? url : nil
        }

        cache.prefetchTiles([tile])
        let data = try waitForReadyTile(tile, in: cache)

        XCTAssertEqual(data.width, 3)
        XCTAssertEqual(data.height, 2)
        XCTAssertEqual(data.bytes, [
            10, 10,
            60, 60,
            110, 110,
            160, 160,
            210, 210,
            250, 250
        ])
    }

    func testLoadsRGBPNGIntoInterleavedCoreAndHaloBytes() throws {
        let tile = Tile(x: 7, y: 8, z: 9)
        let url = try makeRGBPNG(width: 2,
                                 height: 2,
                                 rgbBytes: [
                                     10, 20, 0,
                                     30, 40, 0,
                                     50, 60, 0,
                                     70, 80, 0
                                 ])
        let cache = NightLightsTileCache { requestedTile in
            requestedTile == tile ? url : nil
        }

        cache.prefetchTiles([tile])
        let data = try waitForReadyTile(tile, in: cache)

        XCTAssertEqual(data.width, 2)
        XCTAssertEqual(data.height, 2)
        XCTAssertEqual(data.bytes, [
            10, 20,
            30, 40,
            50, 60,
            70, 80
        ])
    }

    func testCapacityEvictsLeastRecentlyUsedTile() throws {
        let tileA = Tile(x: 1, y: 2, z: 3)
        let tileB = Tile(x: 2, y: 2, z: 3)
        let urlA = try makeJPEG(width: 1, height: 1, bytes: [64])
        let urlB = try makeJPEG(width: 1, height: 1, bytes: [192])
        var loadCounts: [Tile: Int] = [:]
        let cache = NightLightsTileCache(capacity: 1) { tile in
            loadCounts[tile, default: 0] += 1
            return tile == tileA ? urlA : urlB
        }

        cache.prefetchTiles([tileA])
        XCTAssertNotNil(try waitForReadyTile(tileA, in: cache))
        cache.prefetchTiles([tileB])
        XCTAssertNotNil(try waitForReadyTile(tileB, in: cache))
        XCTAssertNil(cache.tileData(for: tileA))
        cache.prefetchTiles([tileA])
        XCTAssertNotNil(try waitForReadyTile(tileA, in: cache))

        XCTAssertEqual(loadCounts[tileA], 2)
        XCTAssertEqual(loadCounts[tileB], 1)
    }

    func testCacheHitPromotesTileBeforeEvictingLeastRecentlyUsedTile() throws {
        let tileA = Tile(x: 1, y: 2, z: 3)
        let tileB = Tile(x: 2, y: 2, z: 3)
        let tileC = Tile(x: 3, y: 2, z: 3)
        let urls = [
            tileA: try makeJPEG(width: 1, height: 1, bytes: [64]),
            tileB: try makeJPEG(width: 1, height: 1, bytes: [128]),
            tileC: try makeJPEG(width: 1, height: 1, bytes: [192])
        ]
        var loadCounts: [Tile: Int] = [:]
        let cache = NightLightsTileCache(capacity: 2) { tile in
            loadCounts[tile, default: 0] += 1
            return urls[tile]
        }

        cache.prefetchTiles([tileA])
        XCTAssertNotNil(try waitForReadyTile(tileA, in: cache))
        cache.prefetchTiles([tileB])
        XCTAssertNotNil(try waitForReadyTile(tileB, in: cache))
        XCTAssertNotNil(cache.tileData(for: tileA))
        cache.prefetchTiles([tileC])
        XCTAssertNotNil(try waitForReadyTile(tileC, in: cache))
        XCTAssertNotNil(cache.tileData(for: tileA))
        XCTAssertNil(cache.tileData(for: tileB))
        cache.prefetchTiles([tileB])
        XCTAssertNotNil(try waitForReadyTile(tileB, in: cache))

        XCTAssertEqual(loadCounts[tileA], 1)
        XCTAssertEqual(loadCounts[tileB], 2)
        XCTAssertEqual(loadCounts[tileC], 1)
    }

    func testRemoveAllClearsCacheAndReloadsOnNextLookup() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let url = try makeJPEG(width: 1, height: 1, bytes: [128])
        var loadCount = 0
        let cache = NightLightsTileCache { _ in
            loadCount += 1
            return url
        }

        cache.prefetchTiles([tile])
        XCTAssertNotNil(try waitForReadyTile(tile, in: cache))
        cache.removeAll()
        XCTAssertNil(cache.tileData(for: tile))
        cache.prefetchTiles([tile])
        XCTAssertNotNil(try waitForReadyTile(tile, in: cache))

        XCTAssertEqual(loadCount, 2)
    }

    func testRemoteTileIsServedFromURLCacheWithoutNetwork() throws {
        let tile = Tile(x: 3, y: 5, z: 6)
        // A host that does not resolve: if the load path touched the network instead of
        // the cache the tile would never decode and `waitForReadyTile` would fail.
        let remoteURL = try XCTUnwrap(URL(string: "https://night-lights.invalid/tiles/6_3_5.jpg"))
        let jpegData = try makeJPEGData(width: 2, height: 2, bytes: [0, 80, 160, 255])

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 2
        let urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                diskCapacity: 8 * 1024 * 1024,
                                directory: cacheDirectory)
        configuration.urlCache = urlCache
        let session = URLSession(configuration: configuration)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        // Pre-populate the disk-backed URLCache exactly as a prior warm launch would have.
        let cachedHTTPResponse = try XCTUnwrap(HTTPURLResponse(url: remoteURL,
                                                               statusCode: 200,
                                                               httpVersion: "HTTP/1.1",
                                                               headerFields: ["Content-Type": "image/jpeg"]))
        urlCache.storeCachedResponse(CachedURLResponse(response: cachedHTTPResponse, data: jpegData),
                                     for: URLRequest(url: remoteURL))

        let cache = NightLightsTileCache(urlSession: session) { $0 == tile ? remoteURL : nil }
        cache.prefetchTiles([tile])
        let data = try waitForReadyTile(tile, in: cache)

        XCTAssertEqual(data.tile, tile)
        XCTAssertEqual(data.width, 2)
        XCTAssertEqual(data.height, 2)
    }

    private func makeJPEGData(width: Int, height: Int, bytes: [UInt8]) throws -> Data {
        XCTAssertEqual(bytes.count, width * height)

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var mutableBytes = bytes
        let mutableData = NSMutableData()
        guard let context = CGContext(data: &mutableBytes,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(mutableData as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString,
                                                                 1,
                                                                 nil) else {
            throw XCTSkip("Could not create test JPEG data")
        }

        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return mutableData as Data
    }

    private func makeJPEG(width: Int, height: Int, bytes: [UInt8]) throws -> URL {
        XCTAssertEqual(bytes.count, width * height)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var mutableBytes = bytes
        guard let context = CGContext(data: &mutableBytes,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.jpeg.identifier as CFString,
                                                                1,
                                                                nil) else {
            throw XCTSkip("Could not create test JPEG")
        }

        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func waitForReadyTile(_ tile: Tile,
                                  in cache: NightLightsTileCache,
                                  timeout: TimeInterval = 2.0) throws -> NightLightsTileData {
        let deadline = Date().addingTimeInterval(timeout)
        var data: NightLightsTileData?
        while data == nil && Date() < deadline {
            data = cache.tileData(for: tile)
            if data == nil {
                usleep(10_000)
            }
        }
        return try XCTUnwrap(data)
    }

    private func makePNG(width: Int, height: Int, bytes: [UInt8]) throws -> URL {
        XCTAssertEqual(bytes.count, width * height)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var mutableBytes = bytes
        guard let context = CGContext(data: &mutableBytes,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.png.identifier as CFString,
                                                                1,
                                                                nil) else {
            throw XCTSkip("Could not create test PNG")
        }

        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeRGBPNG(width: Int, height: Int, rgbBytes: [UInt8]) throws -> URL {
        XCTAssertEqual(rgbBytes.count, width * height * 3)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rgbaBytes = [UInt8]()
        rgbaBytes.reserveCapacity(width * height * 4)
        for pixelStart in stride(from: 0, to: rgbBytes.count, by: 3) {
            rgbaBytes.append(rgbBytes[pixelStart])
            rgbaBytes.append(rgbBytes[pixelStart + 1])
            rgbaBytes.append(rgbBytes[pixelStart + 2])
            rgbaBytes.append(255)
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &rgbaBytes,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.png.identifier as CFString,
                                                                1,
                                                                nil) else {
            throw XCTSkip("Could not create test PNG")
        }

        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}

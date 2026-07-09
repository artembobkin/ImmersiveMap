// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO

struct NightLightsTileData {
    let tile: Tile
    let width: Int
    let height: Int

    /// Interleaved two-channel bytes: red light core, then green light halo per pixel.
    /// Grayscale source tiles draw into equal red and green values for backward compatibility.
    let bytes: [UInt8]
}

final class NightLightsTileCache {
    private static let maxPixelCount = 4096 * 4096

    private let capacity: Int
    private let loader: (Tile) -> URL?
    private let urlSession: URLSession
    private let stateQueue = DispatchQueue(label: "ImmersiveMap.NightLightsTileCache.state")
    private let decodeQueue = DispatchQueue(label: "ImmersiveMap.NightLightsTileCache.decode", qos: .utility)

    private var cachedTiles: [Tile: NightLightsTileData] = [:]
    private var tileOrder: [Tile] = []
    private var pendingTiles: Set<Tile> = []
    private var unavailableTiles: Set<Tile> = []
    private var generation: UInt64 = 0

    init(capacity: Int = 128,
         urlSession: URLSession = NightLightsTileCache.makeCachingSession(),
         loader: @escaping (Tile) -> URL?) {
        self.capacity = max(1, capacity)
        self.urlSession = urlSession
        self.loader = loader
    }

    /// Dedicated session whose `URLCache` persists night-lights tiles on disk. The tile
    /// server marks tiles `immutable` with a one-year `max-age`, so the default protocol
    /// cache policy serves warm launches straight from disk without a network round-trip.
    /// Isolated to its own on-disk directory so it never mixes with the vector-tile caches.
    static func makeCachingSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .useProtocolCachePolicy
        let cacheDirectory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ImmersiveMapNightLightsTiles", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                          diskCapacity: 256 * 1024 * 1024,
                                          directory: cacheDirectory)
        return URLSession(configuration: configuration)
    }

    func tileData(for tile: Tile) -> NightLightsTileData? {
        stateQueue.sync {
            guard let cachedTile = cachedTiles[tile] else {
                return nil
            }
            markRecentlyUsed(tile)
            return cachedTile
        }
    }

    func prefetchTiles(_ tiles: [Tile]) {
        for tile in tiles {
            let scheduledGeneration = stateQueue.sync {
                guard cachedTiles[tile] == nil,
                      !pendingTiles.contains(tile),
                      !unavailableTiles.contains(tile) else {
                    return nil as UInt64?
                }
                pendingTiles.insert(tile)
                return generation
            }

            guard let scheduledGeneration else {
                continue
            }

            decodeQueue.async { [weak self] in
                self?.decodeAndStore(tile, generation: scheduledGeneration)
            }
        }
    }

    func removeAll() {
        stateQueue.sync {
            cachedTiles.removeAll()
            tileOrder.removeAll()
            pendingTiles.removeAll()
            unavailableTiles.removeAll()
            generation &+= 1
        }
    }

    private func decodeAndStore(_ tile: Tile, generation scheduledGeneration: UInt64) {
        guard let url = loader(tile),
              let decodedTile = Self.decodeTile(tile, from: url, session: urlSession) else {
            stateQueue.sync {
                guard generation == scheduledGeneration else {
                    return
                }
                pendingTiles.remove(tile)
                unavailableTiles.insert(tile)
            }
            return
        }

        stateQueue.sync {
            guard generation == scheduledGeneration else {
                return
            }
            pendingTiles.remove(tile)
            insert(decodedTile)
        }
    }

    private func insert(_ tileData: NightLightsTileData) {
        cachedTiles[tileData.tile] = tileData
        unavailableTiles.remove(tileData.tile)
        markRecentlyUsed(tileData.tile)

        while tileOrder.count > capacity, let leastRecentlyUsedTile = tileOrder.first {
            cachedTiles.removeValue(forKey: leastRecentlyUsedTile)
            tileOrder.removeFirst()
        }
    }

    private func markRecentlyUsed(_ tile: Tile) {
        tileOrder.removeAll { $0 == tile }
        tileOrder.append(tile)
    }

    private static func decodeTile(_ tile: Tile, from url: URL, session: URLSession) -> NightLightsTileData? {
        guard let source = imageSource(from: url, session: session),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let width = image.width
        let height = image.height
        let pixelCount = width.multipliedReportingOverflow(by: height)
        guard width > 0,
              height > 0,
              !pixelCount.overflow,
              pixelCount.partialValue <= maxPixelCount else {
            return nil
        }

        let rgbaByteCount = pixelCount.partialValue.multipliedReportingOverflow(by: 4)
        let outputByteCount = pixelCount.partialValue.multipliedReportingOverflow(by: 2)
        let bytesPerRow = width.multipliedReportingOverflow(by: 4)
        guard !rgbaByteCount.overflow,
              !outputByteCount.overflow,
              !bytesPerRow.overflow else {
            return nil
        }

        var rgbaBytes = [UInt8](repeating: 0, count: rgbaByteCount.partialValue)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: &rgbaBytes,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow.partialValue,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var bytes = [UInt8](repeating: 0, count: outputByteCount.partialValue)
        for pixelIndex in 0..<pixelCount.partialValue {
            let sourceIndex = pixelIndex * 4
            let outputIndex = pixelIndex * 2
            bytes[outputIndex] = rgbaBytes[sourceIndex]
            bytes[outputIndex + 1] = rgbaBytes[sourceIndex + 1]
        }

        return NightLightsTileData(tile: tile, width: width, height: height, bytes: bytes)
    }

    private static func imageSource(from url: URL, session: URLSession) -> CGImageSource? {
        if url.isFileURL {
            return CGImageSourceCreateWithURL(url as CFURL, nil)
        }

        guard let data = cachedData(from: url, session: session) else {
            return nil
        }
        return CGImageSourceCreateWithData(data as CFData, nil)
    }

    /// Synchronously fetches the tile bytes through the caching session. Runs on the
    /// serial decode queue, so blocking here mirrors the previous `Data(contentsOf:)`
    /// behavior while now going through the disk-backed `URLCache`.
    private static func cachedData(from url: URL, session: URLSession) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        let task = session.dataTask(with: URLRequest(url: url)) { data, response, _ in
            defer { semaphore.signal() }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                return
            }
            resultData = data
        }
        task.resume()
        semaphore.wait()
        return resultData
    }
}

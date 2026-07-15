// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct PreparedTileCacheIdentity {
    let preparedFormatVersion: UInt32
    let styleRevision: UInt32
    let tileSourceRevision: UInt64
    let flatSeparateRoadRenderingMinimumZoom: UInt32
    let textRevision: UInt32
    let labelLanguage: ImmersiveMapSettings.LabelLanguage
    let labelFallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy
    let houseNumbersEnabled: Bool
    let houseNumbersMinimumZoom: UInt32
    let capitalMaximumZoom: UInt32
    let cityMaximumZoom: UInt32
    let smallSettlementMaximumZoom: UInt32
    let landmarkMinimumZoom: UInt32
    let addTestBorders: Bool

    var namespaceComponent: String {
        "s\(styleRevision)-u\(String(tileSourceRevision, radix: 16))-r\(flatSeparateRoadRenderingMinimumZoom)-t\(textRevision)-l\(labelLanguage.preparedTileCacheNamespaceKey)-f\(labelFallbackPolicy.rawValue)-h\(houseNumbersEnabled ? 1 : 0)-z\(houseNumbersMinimumZoom)-c\(capitalMaximumZoom)-y\(cityMaximumZoom)-m\(smallSettlementMaximumZoom)-k\(landmarkMinimumZoom)-b\(addTestBorders ? 1 : 0)"
    }

    static func tileSourceRevision(for network: ImmersiveMapSettings.TileSettings.NetworkSettings) -> UInt64 {
        var hasher = StableFNV1aHasher()
        hasher.combine(network.tileBaseURL.absoluteString)
        hasher.combine(String(network.cacheIdentity))
        switch network.authorizationMode {
        case .bearerHeader:
            hasher.combine("bearerHeader")
        case .accessTokenQuery(let parameterName):
            hasher.combine("accessTokenQuery:\(parameterName)")
        }
        return hasher.finalize()
    }
}

/// All cache instances that target the same root share a serial utility queue
/// and one root-wide index. This prevents two map views from racing atomic
/// replacements/pruning and avoids rescanning every namespace after each save.
/// Внутренне синхронизирован: реестр под `registryLock`, всё остальное состояние
/// мутируется только на последовательной `queue`.
private final class PreparedTileDiskIOCoordinator: @unchecked Sendable {
    private struct Policy {
        var byteQuota: Int64
        var timeToLive: TimeInterval
    }

    private struct IndexedFile {
        let url: URL
        let byteCount: Int64
        let lastAccessDate: Date
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var coordinatorsByRootPath: [String: PreparedTileDiskIOCoordinator] = [:]

    static func shared(rootDirectory: URL, fileManager: FileManager) -> PreparedTileDiskIOCoordinator {
        let key = rootDirectory.standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = coordinatorsByRootPath[key] {
            return existing
        }
        let coordinator = PreparedTileDiskIOCoordinator(rootDirectory: rootDirectory,
                                                        fileManager: fileManager)
        coordinatorsByRootPath[key] = coordinator
        return coordinator
    }

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let queue: DispatchQueue
    private let queueSpecificKey = DispatchSpecificKey<Bool>()
    private var indexedFilesByPath: [String: IndexedFile] = [:]
    private var indexedByteCount: Int64 = 0
    private var isRootIndexPrepared = false
    // The cache root is process-global, so its active policy must be global as
    // well. The most recently initialized map view owns the current policy;
    // operations from older instances never restore stale limits.
    private var policy = Policy(byteQuota: Int64(256 * 1_024 * 1_024),
                                timeToLive: 7 * 24 * 60 * 60)

    private init(rootDirectory: URL, fileManager: FileManager) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.queue = DispatchQueue(label: "ImmersiveMap.PreparedTileDiskCacheIO.\(rootDirectory.path.hashValue)",
                                   qos: .utility)
        queue.setSpecific(key: queueSpecificKey, value: true)
    }

    func enqueue(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    func performSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueSpecificKey) == true {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    func prepare(currentCacheDirectory: URL,
                 clearOnLaunch: Bool,
                 byteQuota: Int64,
                 timeToLive: TimeInterval) throws {
        policy = Policy(byteQuota: max(0, byteQuota), timeToLive: timeToLive)

        let rootExists = fileManager.fileExists(atPath: rootDirectory.path)
        if clearOnLaunch, rootExists {
            try fileManager.removeItem(at: rootDirectory)
            resetIndex()
            isRootIndexPrepared = true
        } else if rootExists == false {
            resetIndex()
            isRootIndexPrepared = true
        }
        try fileManager.createDirectory(at: currentCacheDirectory, withIntermediateDirectories: true)
        if isRootIndexPrepared == false {
            rebuildRootIndex()
            isRootIndexPrepared = true
        }
        prune()
    }

    func clearAndCreate(currentCacheDirectory: URL) throws {
        if fileManager.fileExists(atPath: rootDirectory.path) {
            try fileManager.removeItem(at: rootDirectory)
        }
        resetIndex()
        isRootIndexPrepared = true
        try fileManager.createDirectory(at: currentCacheDirectory, withIntermediateDirectories: true)
    }

    func readFile(at url: URL) -> Data? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            removeBestEffort(url)
            return nil
        }
        if isExpired(lastAccessDate: modificationDate, timeToLive: policy.timeToLive, now: Date()) {
            removeBestEffort(url)
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let byteCount = fileByteCount(attributes: attributes, fallback: data.count)
            upsert(IndexedFile(url: url,
                               byteCount: byteCount,
                               lastAccessDate: modificationDate))
            return data
        } catch {
            removeBestEffort(url)
            return nil
        }
    }

    func markAccessed(_ url: URL) {
        let now = Date()
        do {
            try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            let existing = indexedFilesByPath[indexKey(for: url)]
            let byteCount: Int64
            if let existing {
                byteCount = existing.byteCount
            } else {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                byteCount = fileByteCount(attributes: attributes, fallback: 0)
            }
            upsert(IndexedFile(url: url, byteCount: byteCount, lastAccessDate: now))
        } catch {
            // A hit remains usable even when the file system refuses an atime
            // update. Its previous timestamp simply remains the LRU fallback.
        }
    }

    func writeFile(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)

        let modificationDate = Date()
        try? fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let byteCount = fileByteCount(attributes: attributes, fallback: data.count)
        upsert(IndexedFile(url: url,
                           byteCount: byteCount,
                           lastAccessDate: modificationDate))
        prune()
    }

    func removeFile(at url: URL) {
        removeBestEffort(url)
    }

    private func rebuildRootIndex() {
        resetIndex()

        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let resourceKeySet = Set(resourceKeys)
        guard let enumerator = fileManager.enumerator(at: rootDirectory,
                                                      includingPropertiesForKeys: resourceKeys,
                                                      options: [],
                                                      errorHandler: { _, _ in true }) else {
            return
        }

        let now = Date()
        var emptiedParentDirectories: Set<URL> = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: resourceKeySet),
                  values.isRegularFile == true else {
                continue
            }
            let modificationDate = values.contentModificationDate ?? .distantPast
            if isExpired(lastAccessDate: modificationDate, timeToLive: policy.timeToLive, now: now) {
                if removeBestEffort(url, cleanEmptyParents: false) {
                    emptiedParentDirectories.insert(url.deletingLastPathComponent())
                }
                continue
            }
            upsert(IndexedFile(url: url,
                               byteCount: Int64(max(0, values.fileSize ?? 0)),
                               lastAccessDate: modificationDate))
        }
        for directory in emptiedParentDirectories {
            removeEmptyParentDirectories(startingAt: directory)
        }
    }

    private func prune() {
        let quota = policy.byteQuota
        let now = Date()
        var emptiedParentDirectories: Set<URL> = []

        for entry in Array(indexedFilesByPath.values)
            where isExpired(lastAccessDate: entry.lastAccessDate, timeToLive: policy.timeToLive, now: now) {
            if removeBestEffort(entry.url, cleanEmptyParents: false) {
                emptiedParentDirectories.insert(entry.url.deletingLastPathComponent())
            }
        }

        if indexedByteCount > quota {
            let oldestFirst = indexedFilesByPath.values.sorted { lhs, rhs in
                if lhs.lastAccessDate != rhs.lastAccessDate {
                    return lhs.lastAccessDate < rhs.lastAccessDate
                }
                return lhs.url.path < rhs.url.path
            }
            for entry in oldestFirst where indexedByteCount > quota {
                if removeBestEffort(entry.url, cleanEmptyParents: false) {
                    emptiedParentDirectories.insert(entry.url.deletingLastPathComponent())
                }
            }
        }

        for directory in emptiedParentDirectories {
            removeEmptyParentDirectories(startingAt: directory)
        }
    }

    @discardableResult
    private func removeBestEffort(_ url: URL,
                                  cleanEmptyParents: Bool = true) -> Bool {
        // Compute the lookup key while the file still exists. On macOS,
        // `standardizedFileURL` can change `/var` to `/private/var` after the
        // final path component is removed, which would leave the byte index stale.
        let key = indexKey(for: url)
        do {
            try fileManager.removeItem(at: url)
            forget(indexKey: key)
            if cleanEmptyParents {
                removeEmptyParentDirectories(startingAt: url.deletingLastPathComponent())
            }
            return true
        } catch {
            if fileManager.fileExists(atPath: url.path) == false {
                forget(indexKey: key)
                if cleanEmptyParents {
                    removeEmptyParentDirectories(startingAt: url.deletingLastPathComponent())
                }
                return true
            }
            return false
        }
    }

    private func removeEmptyParentDirectories(startingAt directory: URL) {
        var currentDirectory = directory
        while currentDirectory.lastPathComponent != rootDirectory.lastPathComponent {
            if fileManager.fileExists(atPath: currentDirectory.path) {
                guard let contents = try? fileManager.contentsOfDirectory(atPath: currentDirectory.path),
                      contents.isEmpty else {
                    break
                }
                do {
                    try fileManager.removeItem(at: currentDirectory)
                } catch {
                    break
                }
            }
            let parentDirectory = currentDirectory.deletingLastPathComponent()
            guard parentDirectory != currentDirectory else { break }
            currentDirectory = parentDirectory
        }
    }

    private func resetIndex() {
        indexedFilesByPath.removeAll(keepingCapacity: true)
        indexedByteCount = 0
    }

    private func upsert(_ entry: IndexedFile) {
        let key = indexKey(for: entry.url)
        if let replaced = indexedFilesByPath.updateValue(entry, forKey: key) {
            indexedByteCount = subtractClamped(indexedByteCount, replaced.byteCount)
        }
        indexedByteCount = addClamped(indexedByteCount, entry.byteCount)
    }

    private func forget(indexKey: String) {
        guard let removed = indexedFilesByPath.removeValue(forKey: indexKey) else {
            return
        }
        indexedByteCount = subtractClamped(indexedByteCount, removed.byteCount)
    }

    private func indexKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func fileByteCount(attributes: [FileAttributeKey: Any]?, fallback: Int) -> Int64 {
        if let number = attributes?[.size] as? NSNumber {
            return max(0, number.int64Value)
        }
        return Int64(max(0, fallback))
    }

    private func isExpired(lastAccessDate: Date, timeToLive: TimeInterval, now: Date) -> Bool {
        now.timeIntervalSince(lastAccessDate) > timeToLive
    }

    private func addClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private func subtractClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        max(0, lhs - min(lhs, rhs))
    }
}

final class PreparedTileDiskCaching {
    static let preparedFormatVersion: UInt32 = 21

    private let cacheDirectory: URL
    private let cacheIdentity: PreparedTileCacheIdentity
    private let ioCoordinator: PreparedTileDiskIOCoordinator

    init(config: ImmersiveMapSettings,
         cacheIdentity: PreparedTileCacheIdentity,
         fileManager: FileManager = .default,
         baseCachesDirectory: URL? = nil) {
        self.cacheIdentity = cacheIdentity

        let cachesDirectory = baseCachesDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let rootDirectory = cachesDirectory.appendingPathComponent("MapPreparedTiles")
        let currentDirectory = rootDirectory
            .appendingPathComponent("v\(cacheIdentity.preparedFormatVersion)")
            .appendingPathComponent(cacheIdentity.namespaceComponent)
        self.cacheDirectory = currentDirectory
        self.ioCoordinator = PreparedTileDiskIOCoordinator.shared(rootDirectory: rootDirectory,
                                                                  fileManager: fileManager)

        let coordinator = ioCoordinator
        let clearOnLaunch = config.tiles.cache.clearDiskCachesOnLaunch
        let quota = Int64(max(0, config.tiles.cache.preparedDiskCacheSizeInBytes))
        let timeToLive = config.tiles.cache.preparedDiskTimeToLive
        coordinator.enqueue {
            do {
                try coordinator.prepare(currentCacheDirectory: currentDirectory,
                                        clearOnLaunch: clearOnLaunch,
                                        byteQuota: quota,
                                        timeToLive: timeToLive)
            } catch {
#if DEBUG
                print("Failed to initialize prepared tile cache: \(error)")
#endif
            }
        }
    }

    /// Loads the cached prepared tile. When `matchingETag` is non-nil the entry is
    /// returned only if it was derived from that exact raw-tile ETag (content-fresh
    /// reuse); nil accepts any cached entry regardless of ETag (offline fallback).
    func requestPreparedDiskCached(tile: Tile, matchingETag: String?) async -> PreparedTileCPU? {
        await withCheckedContinuation { (continuation: CheckedContinuation<PreparedTileCPU?, Never>) in
            ioCoordinator.enqueue { [self] in
                let cachePath = cachePathFor(tile: tile)
                guard let data = ioCoordinator.readFile(at: cachePath) else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    let preparedTile = try PreparedTileDiskCodec.decode(data: data,
                                                                        expectedTile: tile,
                                                                        cacheIdentity: cacheIdentity,
                                                                        expectedSourceETag: matchingETag)
                    ioCoordinator.markAccessed(cachePath)
                    continuation.resume(returning: preparedTile)
                } catch PreparedTileDiskCodecError.invalidMetadata {
                    // Identity/ETag mismatches are benign. Keep the entry for an
                    // offline fallback and let a fresh parse atomically replace it.
                    continuation.resume(returning: nil)
                } catch {
                    ioCoordinator.removeFile(at: cachePath)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func saveOnDisk(tile: Tile,
                    preparedTile: PreparedTileCPU,
                    sourceETag: String?) async {
        guard preparedTile.tile == tile else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioCoordinator.enqueue { [self] in
                defer { continuation.resume() }
                let cachePath = cachePathFor(tile: tile)
                do {
                    let data = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                                cacheIdentity: cacheIdentity,
                                                                sourceETag: sourceETag ?? "")
                    try ioCoordinator.writeFile(data, to: cachePath)
                } catch {
#if DEBUG
                    print("Failed to save prepared tile to \(cachePath.path): \(error)")
#endif
                }
            }
        }
    }

    func removeFromDisk(tile: Tile) {
        let cachePath = cachePathFor(tile: tile)
        ioCoordinator.enqueue { [ioCoordinator] in
            ioCoordinator.removeFile(at: cachePath)
        }
    }

    func clearAllCache() throws {
        try ioCoordinator.performSync { [ioCoordinator, cacheDirectory] in
            try ioCoordinator.clearAndCreate(currentCacheDirectory: cacheDirectory)
        }
    }

    func cachePathFor(tile: Tile) -> URL {
        let fileName = "\(tile.z)_\(tile.x)_\(tile.y).ptile"
        return cacheDirectory.appendingPathComponent(fileName)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// Async loader and LRU owner of scene model meshes, keyed and deduplicated by
/// source URL: any number of models sharing a source share one loaded mesh.
/// Load completion invalidates a frame through `eventSink`, matching the tile
/// pipeline; failures retry with a growing cooldown whose expiry also
/// invalidates a frame (on-demand rendering would otherwise wait for a gesture).
/// Thread-safe (`@unchecked Sendable`): all mutable state is serialized by `lock`.
final class SceneModelMeshStore: @unchecked Sendable {
    static let defaultCostLimitBytes = 128 * 1024 * 1024
    static let maxLoadAttempts = 3
    static let retryCooldownBase: TimeInterval = 5.0

    private enum LoadState {
        case loading(attempt: Int)
        case failed(attempts: Int, retryAt: TimeInterval)
    }

    weak var eventSink: RenderFrameEventSink?

    private let device: MTLDevice
    private let loadAsset: @Sendable (URL, MTLDevice) throws -> SceneModelMesh
    private let lock = NSLock()
    private var cache: LRUMemoryCache<URL, SceneModelMesh>
    private var statesByURL: [URL: LoadState] = [:]
    private var referencedURLs: Set<URL> = []

    init(device: MTLDevice,
         costLimitBytes: Int = SceneModelMeshStore.defaultCostLimitBytes,
         loadAsset: @escaping @Sendable (URL, MTLDevice) throws -> SceneModelMesh = { url, device in
             try SceneModelAssetLoader.load(url: url, device: device)
         }) {
        self.device = device
        self.cache = LRUMemoryCache(costLimit: costLimitBytes)
        self.loadAsset = loadAsset
    }

    /// One call per frame: remembers the referenced set (protected from
    /// eviction), starts loads for missing sources, restarts due retries, and
    /// returns the meshes that are ready right now.
    func requestMeshes(for urls: Set<URL>) -> [URL: SceneModelMesh] {
        lock.lock()
        referencedURLs = urls
        var readyMeshes: [URL: SceneModelMesh] = [:]
        var urlsToLoad: [(url: URL, attempt: Int)] = []
        let now = Date().timeIntervalSinceReferenceDate
        for url in urls {
            if let mesh = cache.value(forKey: url) {
                readyMeshes[url] = mesh
                continue
            }
            switch statesByURL[url] {
            case .loading:
                break
            case .failed(let attempts, let retryAt):
                if attempts < Self.maxLoadAttempts, now >= retryAt {
                    let attempt = attempts + 1
                    statesByURL[url] = .loading(attempt: attempt)
                    urlsToLoad.append((url, attempt))
                }
            case nil:
                statesByURL[url] = .loading(attempt: 1)
                urlsToLoad.append((url, 1))
            }
        }
        lock.unlock()

        for load in urlsToLoad {
            startLoad(url: load.url)
        }
        return readyMeshes
    }

    /// Current load failure for diagnostics/tests; nil while loading or ready.
    func failureAttempts(for url: URL) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard case .failed(let attempts, _) = statesByURL[url] else { return nil }
        return attempts
    }

    func handleMemoryWarning() {
        lock.lock()
        _ = cache.trim(toCost: 0, protectedKeys: referencedURLs)
        statesByURL = statesByURL.filter { _, state in
            if case .loading = state { return true }
            return false
        }
        lock.unlock()
    }

    func evict() {
        lock.lock()
        _ = cache.trim(toCost: Self.defaultCostLimitBytes, protectedKeys: referencedURLs)
        lock.unlock()
    }

    private func startLoad(url: URL) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let mesh = try self.loadAsset(url, self.device)
                self.finishLoad(url: url, mesh: mesh)
            } catch {
                self.failLoad(url: url)
            }
        }
    }

    private func finishLoad(url: URL, mesh: SceneModelMesh) {
        lock.lock()
        statesByURL.removeValue(forKey: url)
        _ = cache.setValue(mesh,
                           forKey: url,
                           cost: mesh.costInBytes,
                           protectedKeys: referencedURLs)
        lock.unlock()
        eventSink?.invalidate(.sceneModelAssetLoaded)
    }

    private func failLoad(url: URL) {
        lock.lock()
        guard case .loading(let attempt) = statesByURL[url] else {
            lock.unlock()
            return
        }
        let cooldown = Self.retryCooldownBase * Double(attempt)
        statesByURL[url] = .failed(attempts: attempt,
                                   retryAt: Date().timeIntervalSinceReferenceDate + cooldown)
        let shouldScheduleRetry = attempt < Self.maxLoadAttempts
        lock.unlock()

        guard shouldScheduleRetry else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + cooldown) { [weak self] in
            self?.eventSink?.invalidate(.sceneModelAssetLoaded)
        }
    }
}

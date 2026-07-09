// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

struct TerrainTileDrawItem {
    let visibleTile: VisibleTile
    let sourceTile: Tile
    let mesh: MetalTerrainMesh
}

final class TerrainTileStore {
    static let heightScale: Float = 1.0
    private static let maxCachedMeshMemoryCost = 48 * 1024 * 1024

    private let metalDevice: MTLDevice
    private let lock = NSLock()
    private let meshCache = TerrainMeshMemoryCache<MetalTerrainMesh>(maxCost: maxCachedMeshMemoryCost)
    private let inFlightRegistry = TerrainTileInFlightRegistry()

    weak var eventSink: RenderFrameEventSink?

    init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
    }

    func requestVisibleTiles(_ visibleTiles: [VisibleTile],
                             terrain: ImmersiveMapSettings.TerrainSettings,
                             renderSurfaceMode: ViewMode,
                             globeRadius: Float) {
        guard let source = terrain.source else {
            return
        }

        let plans = TerrainTileRequestPlanner.drawPlans(visibleTiles: visibleTiles,
                                                        terrain: terrain,
                                                        renderSurfaceMode: renderSurfaceMode,
                                                        globeRadius: globeRadius,
                                                        heightScale: Self.heightScale)
        for plan in plans {
            request(plan: plan, source: source, terrain: terrain, globeRadius: globeRadius)
        }
    }

    func drawItems(visibleTiles: [VisibleTile],
                   terrain: ImmersiveMapSettings.TerrainSettings,
                   renderSurfaceMode: ViewMode,
                   globeRadius: Float) -> [TerrainTileDrawItem] {
        let plans = TerrainTileRequestPlanner.drawPlans(visibleTiles: visibleTiles,
                                                        terrain: terrain,
                                                        renderSurfaceMode: renderSurfaceMode,
                                                        globeRadius: globeRadius,
                                                        heightScale: Self.heightScale)
        var items: [TerrainTileDrawItem] = []
        items.reserveCapacity(plans.count)

        lock.lock()
        defer { lock.unlock() }
        for plan in plans {
            guard let mesh = meshCache.mesh(for: plan.cacheKey) else {
                continue
            }
            items.append(TerrainTileDrawItem(visibleTile: plan.visibleTile,
                                             sourceTile: plan.sourceTile,
                                             mesh: mesh))
        }
        return items
    }

    func handleMemoryWarning() {
        clear()
    }

    func evict() {
        clear()
    }

    private func request(plan: TerrainTileRequestPlan,
                         source: ImmersiveMapTerrainSource,
                         terrain: ImmersiveMapSettings.TerrainSettings,
                         globeRadius: Float) {
        lock.lock()
        if meshCache.mesh(for: plan.cacheKey) != nil {
            lock.unlock()
            return
        }
        guard let token = inFlightRegistry.reserve(key: plan.cacheKey) else {
            lock.unlock()
            return
        }
        lock.unlock()

        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await self.load(plan: plan,
                            source: source,
                            terrain: terrain,
                            globeRadius: globeRadius,
                            token: token)
        }

        lock.lock()
        let didAttach = inFlightRegistry.attach(task, for: plan.cacheKey, token: token)
        lock.unlock()
        if didAttach == false {
            task.cancel()
        }
    }

    private func load(plan: TerrainTileRequestPlan,
                      source: ImmersiveMapTerrainSource,
                      terrain: ImmersiveMapSettings.TerrainSettings,
                      globeRadius: Float,
                      token: TerrainTileInFlightToken) async {
        defer {
            finishRequest(for: plan.cacheKey, token: token)
        }

        let url = TerrainTileURLProvider(source: source).url(for: plan.sourceTile)
        guard let data = try? await fetchData(from: url),
              Task.isCancelled == false,
              let heightGrid = TerrainRGBDecoder.decode(data: data, encoding: source.encoding) else {
            return
        }

        let mesh = makeMesh(plan: plan,
                            heightGrid: heightGrid,
                            terrain: terrain,
                            globeRadius: globeRadius)
        guard Task.isCancelled == false,
              let metalMesh = await MainActor.run(body: { MetalTerrainMesh(device: metalDevice, mesh: mesh) }) else {
            return
        }

        await MainActor.run {
            guard self.store(metalMesh, for: plan.cacheKey, token: token) else {
                return
            }
            self.eventSink?.invalidate(.tileAvailable)
        }
    }

    private func fetchData(from url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    private func makeMesh(plan: TerrainTileRequestPlan,
                          heightGrid: TerrainHeightGrid,
                          terrain: ImmersiveMapSettings.TerrainSettings,
                          globeRadius: Float) -> TerrainMesh {
        switch plan.cacheKey.renderSurfaceMode {
        case .flat:
            return TerrainMeshBuilder.buildFlatMesh(tile: plan.sourceTile,
                                                    heightGrid: heightGrid,
                                                    resolution: terrain.meshResolution,
                                                    exaggeration: terrain.exaggeration,
                                                    heightScale: Self.heightScale)
        case .spherical:
            return TerrainMeshBuilder.buildGlobeMesh(tile: plan.sourceTile,
                                                     heightGrid: heightGrid,
                                                     resolution: terrain.meshResolution,
                                                     globeRadius: globeRadius,
                                                     exaggeration: terrain.exaggeration,
                                                     heightScale: Self.heightScale)
        }
    }

    @discardableResult
    private func store(_ mesh: MetalTerrainMesh,
                       for key: TerrainTileCacheKey,
                       token: TerrainTileInFlightToken) -> Bool {
        lock.lock()
        guard inFlightRegistry.contains(key: key, token: token) else {
            lock.unlock()
            return false
        }
        meshCache.set(mesh, for: key, cost: mesh.estimatedMemoryCost)
        lock.unlock()
        return true
    }

    private func finishRequest(for key: TerrainTileCacheKey,
                               token: TerrainTileInFlightToken) {
        lock.lock()
        inFlightRegistry.finish(key: key, token: token)
        lock.unlock()
    }

    private func clear() {
        lock.lock()
        inFlightRegistry.cancelAll()
        meshCache.removeAll()
        lock.unlock()
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import simd

/// The terrain tiles the flattened ground rises by
/// (`TileSettings.GroundReliefSettings`): loads them from a terrain source
/// and keeps them as textures, with their heights on the CPU.
///
/// The frame states once which terrain tiles it needs, nearest first
/// (`request(tiles:)`, `GroundReliefDemand`), as it states its map tiles:
/// the store loads them in that order, a few at a time
/// (`GroundReliefSettings.maximumConcurrentLoads`), and keeps them while
/// they are wanted. Whatever reads the terrain (`terrain(at:)`,
/// `finestTerrain(over:terrainZoom:orCoarser:)`) only reads, and never
/// starts a load. A terrain tile that arrives invalidates a frame through
/// `eventSink`, as a map tile does, so the on-demand render loop draws it
/// without waiting for a gesture. Its edges are welded to its neighbours'
/// of the same zoom (`GroundReliefEdgeWeld`), so the ground over two tiles
/// meets without a crack, written at the next frame's start
/// (`applyPendingWelds`).
///
/// A terrain tile the source does not have is remembered as missing, and
/// its ancestor is wanted in its place, down to the source's floor. One
/// that could not be fetched is asked again after a pause that grows with
/// each failure (`GroundReliefLoadStates`). A load the camera has left
/// behind finishes, as a map tile's does, and lands into nothing. The
/// tiles the frame stopped reading wait in a small cache for the zoom back
/// (`GroundReliefReleasedCache`). `statusSnapshot` tells the debug panel
/// all of it.
///
/// The store holds tiles and nothing of a frame: how far the relief has
/// risen, the datum, the light and every other value a frame draws by are
/// `GroundReliefFrameState`'s, and the draws read them, with the store's
/// tiles, through the frame's `GroundReliefFrame`. The planner reaches the
/// store through `GroundReliefTerrainDemand` alone.
///
/// Thread-safe (`@unchecked Sendable`): the loads run in tasks off the main
/// thread and all mutable state is serialized by `lock`.
///
/// The main type of `Tile/Relief`, the relief's core. The relief draws
/// nothing of its own: it changes how other features draw, so its code
/// lies in a `Relief` folder of each feature it changes, and this folder
/// holds what they all share: the terrain tiles, their source and this
/// store (`GroundReliefTile`, `GroundReliefTerrainSource`,
/// `GroundReliefLoadStates`, `GroundReliefReleasedCache`,
/// `GroundReliefOcclusionScheduler`), the frame's relief
/// (`GroundReliefFrameState`, `GroundReliefFrame`), the heights read on the
/// CPU (`GroundRelief`, `GroundReliefTileLift`), the frame's datum
/// (`GroundReliefCameraLift`), the GPU side every rising draw binds
/// (`GroundReliefUniform`, `Shaders/GroundRelief.h`), and the relief of the
/// tile's own features, the ground and the buildings
/// (`BuildingReliefLifts`). It holds no drawing and no parsing, and
/// depends on nothing of a feature but the tile's address. The other
/// features' relief lies in their own `Relief` folders
/// (`Camera/Relief`), and a feature whose relief is a call into this
/// core (the labels) keeps the call where it is.
final class GroundReliefStore: GroundReliefTerrainDemand, @unchecked Sendable {
    weak var eventSink: RenderFrameEventSink?

    /// What a draw samples for a tile whose occlusion of the sky is not
    /// computed: one texel of 0, no darkening.
    var occlusionFallbackTexture: MTLTexture? { occlusion.fallbackTexture }

    private let device: MTLDevice
    private let source: any GroundReliefTerrainSource
    private let minimumSourceZoom: Int
    private let now: @Sendable () -> TimeInterval
    private let occlusion: GroundReliefOcclusionScheduler

    private let lock = NSLock()
    private var terrains: [Tile: GroundReliefTile] = [:]
    private var released: GroundReliefReleasedCache
    private var loads: GroundReliefLoadStates
    /// The frame's demand (`request(tiles:)`), nearest first, and the same
    /// as a set: loaded in that order, and what the store keeps.
    private var wantedOrder: [Tile] = []
    private var wantedTiles: Set<Tile> = []
    /// The welds of the tiles' edges to their neighbours' still to write
    /// (`GroundReliefEdgeWeld`), queued as the tiles arrive and written at
    /// the next frame's start (`applyPendingWelds`).
    private var pendingWelds: [GroundReliefEdgeWeld.Write] = []
    private var currentVersion: UInt64 = 0
    private var currentZooms: GroundReliefTerrainZooms
    private var heightRange: ClosedRange<Float>?
    private var heightRangeVersion: UInt64?

    /// `source` gives the tiles' heights, `occlusionKey` is what their
    /// occlusion of the sky is computed with until the frame says
    /// otherwise (`setOcclusionKey`), and `now` is the clock the retries
    /// wait by, a test's seam.
    init(device: MTLDevice,
         settings: ImmersiveMapSettings.TileSettings.GroundReliefSettings,
         source: any GroundReliefTerrainSource,
         occlusionKey: GroundReliefOcclusion.Key = GroundReliefOcclusion.Key(style: ImmersiveMapTerrainOcclusion()),
         now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.device = device
        self.source = source
        self.minimumSourceZoom = max(0, settings.minimumSourceZoom)
        self.now = now
        self.occlusion = GroundReliefOcclusionScheduler(device: device, key: occlusionKey)
        self.released = GroundReliefReleasedCache(capacityBytes: settings.releasedCacheBytes)
        self.loads = GroundReliefLoadStates(maximumConcurrentLoads: settings.maximumConcurrentLoads)
        self.currentZooms = GroundReliefTerrainZooms(cameraZoom: max(0, settings.cameraTerrainZoom),
                                                     displacementMaximumZoom: max(0, settings.displacementMaximumZoom))
    }

    /// The texels across a terrain tile: Mapterhorn's 512. The camera's
    /// march is stepped by it (`CameraTerrainFollow.sampleStepWorld`), and
    /// the relief's detail matches the terrain to the grids by it
    /// (`GroundReliefTerrainZooms`). A source of coarser tiles is marched
    /// finer than its texel and read a zoom finer than its heights need,
    /// which costs samples and tiles and nothing else.
    static let nominalTerrainTileSize = 512

    // MARK: - What the terrain is

    /// Grows with every terrain tile that arrives, leaves, is welded or
    /// turns out not to come, and with every occlusion computed: what is
    /// placed by the terrain (the planner's placements, the labels) is
    /// placed again when it changes.
    var version: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return currentVersion
    }

    /// Which terrain tiles the ground and the camera read this frame: the
    /// frame's ring bands' terrain (`setBands`) and the camera's map.
    var zooms: GroundReliefTerrainZooms {
        lock.lock()
        defer { lock.unlock() }
        return currentZooms
    }

    /// The zoom of the terrain tiles the camera reads
    /// (`GroundReliefSettings.cameraTerrainZoom`).
    var cameraTerrainZoom: Int { zooms.cameraZoom }

    /// The frame's ring bands (`VisibleContentState.flatRingBands`, through
    /// `GroundReliefFrameState.setBands`, once a frame, before anything of
    /// the frame reads the relief): each band's ground reads the terrain
    /// zoom its rule gave it (`FlatRingRule.terrainZoomDrop`).
    func setBands(_ bands: [FlatRingBand]) {
        lock.lock()
        defer { lock.unlock() }
        currentZooms = GroundReliefTerrainZooms(cameraZoom: currentZooms.cameraZoom,
                                                displacementMaximumZoom: currentZooms.displacementMaximumZoom,
                                                bands: bands)
    }

    /// The zoom a ring of `zoom` reads its terrain at, by the frame's ring
    /// rules (`GroundReliefTerrainZooms.terrainZoom(forTargetZoom:)`).
    func terrainZoom(forTargetZoom zoom: Int) -> Int {
        zooms.terrainZoom(forTargetZoom: zoom)
    }

    /// The lowest and the highest height over every terrain tile in, in
    /// metres before the exaggeration, nil with none in. The coarse tiles
    /// of the far rings span the region around the camera, so the range
    /// is the region's, the peaks not yet drawn included. The coverage
    /// walks the frustum's footprint over this range of ground
    /// (`CoveragePolygonBuilder`), so a tile the relief lifts into view
    /// past the plane's footprint is drawn.
    var heightRangeMetres: ClosedRange<Float>? {
        lock.lock()
        defer { lock.unlock() }
        if heightRangeVersion != currentVersion {
            var range: ClosedRange<Float>?
            for tile in terrains.values {
                range = range.map { min($0.lowerBound, tile.heightRange.lowerBound) ... max($0.upperBound, tile.heightRange.upperBound) }
                    ?? tile.heightRange
            }
            heightRange = range
            heightRangeVersion = currentVersion
        }
        return heightRange
    }

    /// A terrain tile in, with its occlusion of the sky when that is
    /// computed under the current key: nil for a tile not in, which
    /// includes one the source has not got or does not answer for.
    func terrain(at source: Tile) -> (terrain: GroundReliefTile, occlusion: MTLTexture?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let terrain = terrains[source] else { return nil }
        return (terrain, terrain.occlusionKey == occlusion.key ? terrain.occlusion : nil)
    }

    /// The terrain tile of `terrainZoom` over `tile` (its own address when
    /// that is coarser) or, while that is on its way, the finest coarser
    /// one in. `orCoarser` false asks for the terrain of `terrainZoom` only.
    /// Nil while no terrain over the tile is in at all.
    func finestTerrain(over tile: Tile, terrainZoom: Int, orCoarser: Bool = true) -> (source: Tile, terrain: GroundReliefTile)? {
        lock.lock()
        defer { lock.unlock() }
        var source = tile.findParentTile(atZoom: max(min(terrainZoom, tile.z), 0)) ?? tile
        while true {
            if let terrain = terrains[source] {
                return (source, terrain)
            }
            guard orCoarser, source.z > 0, let parent = source.findParentTile(atZoom: source.z - 1) else {
                return nil
            }
            source = parent
        }
    }

    // MARK: - Demand

    /// The terrain tile a source drawn in a ring of `targetZoom` rises by,
    /// the one the planner binds its placement to once it is in
    /// (`TilePlacementPlanner`, `PlaceTile.terrain`) and the frame demands
    /// with the tile (`GroundReliefDemand`): the ring's terrain over the
    /// tile (`GroundReliefTerrainZooms.terrainTile(for:targetZoom:)`), or,
    /// where the source has no such tile, the finest ancestor it has, down
    /// to the source's floor (`minimumSourceZoom`). The rings' terrain
    /// whether or not the frame is on the terrain: a frame collapsed into
    /// the plane past the relief's zooms still asks for it
    /// (`TileWorkingSetSubsystem`), so the rise back finds every
    /// placement's terrain in and binds it at once, and binds nothing while
    /// it is flat (`TilePlacementPlanner`).
    func terrainSource(for tile: Tile, targetZoom: Int) -> Tile {
        lock.lock()
        defer { lock.unlock() }
        return existingSourceLocked(of: currentZooms.terrainTile(for: tile, targetZoom: targetZoom))
    }

    /// The terrain tile a source drawn in a ring of `targetZoom` displaces
    /// its grid by (`PlaceTile.displacement`): the ring's terrain no finer
    /// than the displacement's zoom (`GroundReliefTerrainZooms
    /// .displacementTile(for:targetZoom:)`), or the finest ancestor the
    /// source has, as `terrainSource(for:targetZoom:)`. The same tile as the
    /// shading's where the ring's terrain is no finer.
    func displacementSource(for tile: Tile, targetZoom: Int) -> Tile {
        lock.lock()
        defer { lock.unlock() }
        return existingSourceLocked(of: currentZooms.displacementTile(for: tile, targetZoom: targetZoom))
    }

    /// Whether a terrain tile is in, or counts as in because it cannot
    /// come (`GroundReliefLoadStates.isUnavailable`). The planner binds a
    /// placement to a resident tile (`TilePlacementPlanner`), and one bound
    /// to a tile that cannot come draws flat
    /// (`GroundReliefFrame.relief(for:terrain:)`): a map whose terrain
    /// source is out of reach shows its tiles on the plane, not holes.
    func isResident(_ tile: Tile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terrains[tile] != nil || loads.isUnavailable(tile)
    }

    /// Whether a wanted tile is still to come: on its way, or failed and
    /// waiting for its retry. The frame keeps asking (`request(tiles:)`,
    /// `TileWorkingSetSubsystem`) while one is, as it keeps asking for a
    /// map tile in flight: the retries start from the asking.
    var hasLoadsPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wantedOrder.contains { terrains[$0] == nil }
    }

    /// The wanted terrain tiles still on their way
    /// (`GroundReliefLoadStates.pendingCount`): what a still capture
    /// settles on (`FrameDiagnostics.Counter.pendingTerrainTiles`).
    var pendingWantedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads.pendingCount(wanted: wantedOrder, isLoaded: { terrains[$0] != nil }, now: now())
    }

    /// The frame's terrain demand, once a frame (`TileWorkingSetSubsystem`):
    /// the terrain the frame reads, nearest first (`GroundReliefDemand`),
    /// out of what the planner planned. It is asked for on the terrain and
    /// while the relief is collapsed past its zooms
    /// (`GroundReliefSettings.collapseZoom`), then for the tiles of the
    /// collapse's zoom the relief reads when it rises back, no finer, so the
    /// rise finds every placement's terrain in. Below the relief's tile
    /// zoom, and off the flat map, nothing.
    func request(for relief: GroundReliefFrame,
                 onFlatMap: Bool,
                 tileZoom: Int,
                 targets: [VisibleTile],
                 shown: [PlaceTile],
                 missing: [Tile],
                 centerWorldMercator: SIMD2<Double>) {
        guard onFlatMap, relief.isActive || tileZoom >= relief.fromTileZoom else {
            request(tiles: [])
            return
        }
        request(tiles: GroundReliefDemand.tiles(targets: targets,
                                                shown: shown,
                                                also: missing,
                                                centerWorldMercator: centerWorldMercator,
                                                zooms: zooms,
                                                maximumTargetZoom: relief.isActive ? .max : relief.collapseTileZoom,
                                                terrainSource: { (self.terrainSource(for: $0, targetZoom: $1),
                                                                  self.displacementSource(for: $0, targetZoom: $1)) }))
    }

    /// The frame's terrain, nearest first (`GroundReliefDemand`): what the
    /// store loads, in that order, and all it keeps. A terrain the frame
    /// no longer asks for, neither for a target nor for a placement shown,
    /// is released here, as the tiles are (`TileRenderStore`), and a load
    /// of one lands into nothing. A tile the source does not have is
    /// replaced by its ancestor, down to the source's floor. Called once a
    /// frame. An empty list wants nothing, which a frame off the terrain
    /// asks. A tile no longer wanted goes to the released cache, and a
    /// wanted tile found there comes back from it at once, welded to its
    /// neighbours in as a loaded one is.
    func request(tiles: [Tile]) {
        lock.lock()
        var order: [Tile] = []
        order.reserveCapacity(tiles.count)
        var seen: Set<Tile> = []
        for tile in tiles {
            let source = existingSourceLocked(of: tile)
            guard loads.isMissing(source) == false, seen.insert(source).inserted else { continue }
            order.append(source)
        }
        wantedOrder = order
        wantedTiles = seen
        var changed = false
        let leaving = terrains.keys.filter { seen.contains($0) == false }
        for tile in leaving {
            if let terrain = terrains.removeValue(forKey: tile) {
                released.keep(tile, terrain: terrain)
                changed = true
            }
        }
        for tile in order where terrains[tile] == nil {
            guard let terrain = released.take(tile) else { continue }
            terrains[tile] = terrain
            pendingWelds += GroundReliefEdgeWeld.writes(for: tile, terrain: terrain) { [terrains] neighbour in
                terrains[neighbour]
            }
            changed = true
        }
        if changed {
            currentVersion &+= 1
        }
        startWantedLoadsLocked()
        lock.unlock()
    }

    /// Releases every terrain tile, for a memory warning. The placements
    /// bound to them are planned again when their terrain is back.
    func removeAll() {
        lock.lock()
        terrains.removeAll()
        released.removeAll()
        currentVersion &+= 1
        lock.unlock()
    }

    /// `tile` or, where the source has no such tile, the finest ancestor
    /// it has, down to the floor. Called under `lock`.
    private func existingSourceLocked(of tile: Tile) -> Tile {
        var source = tile
        while loads.isMissing(source), source.z > minimumSourceZoom,
              let parent = source.findParentTile(atZoom: source.z - 1) {
            source = parent
        }
        return source
    }

    // MARK: - The occlusion of the sky

    /// What the tiles' occlusion of the sky is computed with
    /// (`GroundReliefFrameState.setOcclusion`). A new key computes every
    /// tile in, and every tile kept, again on a queue of its own, and each
    /// tile draws its new occlusion as it is done. Until then a tile draws
    /// none (`terrain(at:)`).
    func setOcclusionKey(_ key: GroundReliefOcclusion.Key) {
        lock.lock()
        guard let generation = occlusion.begin(key) else {
            lock.unlock()
            return
        }
        let tiles = (Array(terrains.map { (tile: $0.key, terrain: $0.value) }) + released.all)
            .map { (tile: $0.tile, terrain: $0.terrain, halves: $0.terrain.halves) }
        lock.unlock()
        occlusion.recompute(tiles, key: key, generation: generation) { [weak self] terrain, texture in
            guard let self else { return }
            self.lock.lock()
            if self.occlusion.isCurrent(generation) {
                terrain.setOcclusion(texture, key: key)
                self.currentVersion &+= 1
            }
            self.lock.unlock()
            self.eventSink?.invalidate(.tileAvailable)
        }
    }

    // MARK: - Welds

    /// Writes the welds queued since the last frame
    /// (`GroundReliefEdgeWeld`): the texels on the CPU, here on the main
    /// thread, where they are read, and the textures through a blit in a
    /// command buffer of the frame's queue, committed before the frame's
    /// own. Metal tracks the textures' hazards in a queue's order, so the
    /// blit lands after every frame before it has read them and before
    /// this frame reads them: no texture changes under a frame in flight.
    /// Called once a frame, before the frame's command buffer
    /// (`RenderFrameEngine`). Returns the blit's command buffer, nil with
    /// nothing to write.
    @discardableResult
    func applyPendingWelds(commandQueue: MTLCommandQueue) -> MTLCommandBuffer? {
        lock.lock()
        let writes = pendingWelds
        pendingWelds.removeAll()
        lock.unlock()
        guard writes.isEmpty == false else { return nil }

        var staging: [UInt16] = []
        staging.reserveCapacity(writes.reduce(0) { $0 + $1.values.count })
        var offsets: [Int] = []
        for write in writes {
            write.terrain.writeTexels(write.values, x: write.x, y: write.y, width: write.width, height: write.height)
            offsets.append(staging.count * MemoryLayout<UInt16>.stride)
            staging += write.values
        }
        guard let buffer = staging.withUnsafeBytes({ bytes in
                  device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
              }),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        commandBuffer.label = "GroundReliefEdgeWeld"
        for (write, offset) in zip(writes, offsets) {
            let rowBytes = write.width * MemoryLayout<UInt16>.stride
            blit.copy(from: buffer,
                      sourceOffset: offset,
                      sourceBytesPerRow: rowBytes,
                      sourceBytesPerImage: rowBytes * write.height,
                      sourceSize: MTLSize(width: write.width, height: write.height, depth: 1),
                      to: write.terrain.texture,
                      destinationSlice: 0,
                      destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: write.x, y: write.y, z: 0))
        }
        blit.endEncoding()
        commandBuffer.commit()
        // What is placed by the terrain on the CPU (the labels) is placed
        // again on the welded edges.
        lock.lock()
        currentVersion &+= 1
        lock.unlock()
        return commandBuffer
    }

    // MARK: - Status

    /// What the store holds and does now, for the debug panel's relief
    /// tab, with the frame's own values (`GroundReliefFrame.statusSnapshot`).
    func statusSnapshot(isActive: Bool, standingShare: Float, datumMetres: Float) -> GroundReliefStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let time = now()
        let occlusionKey = occlusion.key
        var tiles: [GroundReliefStatusSnapshot.TileStatus] = []
        var listed: Set<Tile> = []
        var wantedResident = 0
        func status(of tile: Tile, priority: Int?) -> GroundReliefStatusSnapshot.TileStatus {
            if let terrain = terrains[tile] {
                return .init(tile: tile, state: .resident, priority: priority, bytes: terrain.costInBytes,
                             heightRange: terrain.heightRange, seconds: 0, attempts: 0)
            }
            switch loads.statesByTile[tile] {
            case .loading(let failedAttempts):
                let started = loads.startedAt[tile] ?? time
                return .init(tile: tile, state: .loading, priority: priority, bytes: 0, heightRange: nil,
                             seconds: Int(max(0, time - started)), attempts: failedAttempts)
            case .failed(let attempts, let retryAt):
                return .init(tile: tile, state: .failed, priority: priority, bytes: 0, heightRange: nil,
                             seconds: Int(max(0, retryAt - time).rounded(.up)), attempts: attempts)
            case nil:
                return .init(tile: tile, state: .queued, priority: priority, bytes: 0, heightRange: nil,
                             seconds: 0, attempts: 0)
            }
        }
        for (priority, tile) in wantedOrder.enumerated() {
            let entry = status(of: tile, priority: priority)
            if entry.state == .resident { wantedResident += 1 }
            tiles.append(entry)
            listed.insert(tile)
        }
        let kept = (Array(terrains.keys) + Array(loads.statesByTile.keys)).filter { listed.contains($0) == false }
        for tile in Set(kept).sorted(by: { ($0.z, $0.x, $0.y) < ($1.z, $1.x, $1.y) }) {
            tiles.append(status(of: tile, priority: nil))
        }
        return GroundReliefStatusSnapshot(tiles: tiles,
                                          isActive: isActive,
                                          standingShare: standingShare,
                                          datumMetres: datumMetres,
                                          cameraTerrainZoom: currentZooms.cameraZoom,
                                          terrainByRing: currentZooms.statusText,
                                          wantedCount: wantedOrder.count,
                                          wantedResidentCount: wantedResident,
                                          residentCount: terrains.count,
                                          residentBytes: terrains.values.reduce(0) { $0 + $1.costInBytes },
                                          releasedCount: released.count,
                                          releasedBytes: released.bytes,
                                          releasedCacheBytes: released.capacityBytes,
                                          occlusionComputedCount: terrains.values.count { $0.occlusion != nil && $0.occlusionKey == occlusionKey },
                                          occlusionMillisecondsLast: occlusion.millisecondsLast,
                                          loadingCount: loads.activeLoads,
                                          maximumConcurrentLoads: loads.maximumConcurrentLoads,
                                          failedCount: loads.failedCount,
                                          missingCount: loads.missing.count)
    }

    // MARK: - Loading

    /// Starts the loads of the wanted tiles that are neither in nor on
    /// their way, nearest first, while slots are free. Called under `lock`.
    private func startWantedLoadsLocked() {
        let started = loads.start(wanted: wantedOrder, isLoaded: { terrains[$0] != nil }, now: now())
        for tile in started {
            startLoad(tile)
        }
    }

    private func startLoad(_ tile: Tile) {
        let source = self.source
        let device = self.device
        Task.detached(priority: .utility) { [weak self] in
            do {
                switch try await source.heights(of: tile) {
                case .heights(let heights):
                    let terrain = try GroundReliefTile.make(heights: heights, device: device)
                    guard let self else { return }
                    self.applyOcclusion(to: terrain, tile: tile)
                    self.finishLoad(tile, terrain: terrain)
                case .missing:
                    self?.finishLoad(tile, terrain: nil)
                }
            } catch {
                self?.failLoad(tile)
            }
        }
    }

    /// The occlusion of a tile just decoded, under the key of the moment,
    /// before the tile is in: on the load's own task.
    private func applyOcclusion(to terrain: GroundReliefTile, tile: Tile) {
        let computed = occlusion.compute(tile: tile, terrain: terrain)
        lock.lock()
        terrain.setOcclusion(computed.texture, key: computed.key)
        lock.unlock()
    }

    /// A load that ended: the terrain, or nil for a tile the source does
    /// not have (or cannot be read), which is then remembered as missing.
    private func finishLoad(_ tile: Tile, terrain: GroundReliefTile?) {
        lock.lock()
        loads.finish(tile, missing: terrain == nil)
        if let terrain {
            // A load the frame no longer wants lands into nothing.
            if wantedTiles.contains(tile) {
                terrains[tile] = terrain
                currentVersion &+= 1
                // Its edges to the neighbours in, and theirs to it: written
                // with the frame, never into a texture a frame may be reading.
                pendingWelds += GroundReliefEdgeWeld.writes(for: tile, terrain: terrain) { [terrains] neighbour in
                    terrains[neighbour]
                }
            }
        } else {
            // The planner reads the tile as in and flat (`isResident`).
            currentVersion &+= 1
        }
        startWantedLoadsLocked()
        lock.unlock()
        // A missing tile changes no picture, but the next frame asks for
        // its ancestor, or places the tile flat.
        eventSink?.invalidate(.tileAvailable)
    }

    private func failLoad(_ tile: Tile) {
        lock.lock()
        let failure = loads.fail(tile, now: now())
        if failure.becameUnavailable {
            // The planner reads the tile as in and flat from now on
            // (`isResident`): a plan over it.
            currentVersion &+= 1
        }
        startWantedLoadsLocked()
        lock.unlock()

        // The pause's end must draw a frame: on-demand rendering would
        // otherwise wait for a gesture.
        eventSink?.invalidate(.tileAvailable)
        DispatchQueue.main.asyncAfter(deadline: .now() + failure.delay) { [weak self] in
            self?.eventSink?.invalidate(.tileAvailable)
        }
    }
}

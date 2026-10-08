// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import simd

/// A raster tile the frame draws: its texture in one target's place.
struct RasterTilePlacement {
    let key: RasterTileKey
    let texture: MTLTexture
    let placeIn: VisibleTile
}

/// The raster tiles: a ring rule with a raster size
/// (`FlatRingRule.rasterSize`) draws its tiles' ground from a texture of
/// their fills instead of from their geometry. A texture is drawn once from
/// its tile (`bake`), kept on disk (`RasterTileDiskCache`) and from then on
/// loaded from its file, the vector tile not needed at all unless the rule
/// draws its lines or labels over it.
///
/// The frame asks for the textures it wants (`request`), nearest first.
/// A texture on the GPU is handed back. One on disk starts loading, straight
/// into the texture through the device's IO queue where the device has one
/// (`MetalIOCommandQueues`). One that is nowhere is to be baked: the frame
/// then wants the vector tile, and bakes the texture once it is resident,
/// a few a frame (`ImmersiveMapSettings.TileSettings.RasterizationSettings`).
/// A texture that arrives invalidates a frame, as a map tile does. Until
/// then the target's ground draws nothing.
///
/// The textures the frame wants are never released. The others stay until
/// they pass the memory budget, and then the longest unused leave first. A
/// memory warning releases every texture the frame does not want.
///
/// Thread-safe (`@unchecked Sendable`): `request` and `bake` run on the
/// main thread with the frame, the loads and the completions off it, and
/// all mutable state is serialized by `lock`.
final class RasterTileStore: @unchecked Sendable {
    enum Availability: Equatable {
        case resident
        /// On its way from disk or from a bake.
        case pending
        /// Neither on the GPU nor on disk: drawn from its vector tile once
        /// that is resident.
        case needsBake
    }

    struct Request {
        let availability: [RasterTileKey: Availability]
        let textures: [RasterTileKey: MTLTexture]
    }

    /// How many files load at once.
    static let maximumConcurrentLoads = 8
    /// How long one load from disk may take before it counts as failed,
    /// as a map tile's (`MetalTileFactory.fileBlobLoadTimeout`).
    static let fileLoadTimeout: TimeInterval = 15

    weak var eventSink: RenderFrameEventSink?

    private struct Entry {
        let texture: MTLTexture
        let byteCount: Int
        var lastUsedTick: UInt64
    }

    /// Carries a texture across the loads' await points: Metal objects are
    /// thread-safe to use.
    private struct TextureBox: @unchecked Sendable {
        let texture: MTLTexture
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private let pipeline: RasterTilePipeline
    private let diskCache: RasterTileDiskCache?
    private let memoryBudgetInBytes: Int
    let bakesPerFrame: Int
    private let clearColor: MTLClearColor
#if !targetEnvironment(simulator)
    private let ioCommandQueue: MTLIOCommandQueue?
#endif

    private let lock = NSLock()
    private var entries: [RasterTileKey: Entry] = [:]
    private var loading: Set<RasterTileKey> = []
    private var baking: Set<RasterTileKey> = []
    private var wanted: Set<RasterTileKey> = []
    private var usageTick: UInt64 = 0
    private var residentBytes = 0
    private var version: UInt64 = 0
    /// The bake's multisampled target per size, reused by every bake of
    /// that size: its contents end in the resolve.
    private var multisampleTargets: [Int: MTLTexture] = [:]

    init(device: MTLDevice,
         pipeline: RasterTilePipeline,
         diskCache: RasterTileDiskCache?,
         settings: ImmersiveMapSettings.TileSettings.RasterizationSettings,
         baseColor: SIMD4<Float>) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        self.commandQueue?.label = "RasterTileStore"
        self.pipeline = pipeline
        self.diskCache = diskCache
        self.memoryBudgetInBytes = max(0, settings.memoryBudgetInBytes)
        self.bakesPerFrame = max(1, settings.bakesPerFrame)
        // What no fill paints is the map's own ground, the colour the
        // world pass clears to under the vector tiles.
        self.clearColor = MTLClearColor(red: Double(baseColor.x),
                                        green: Double(baseColor.y),
                                        blue: Double(baseColor.z),
                                        alpha: 1)
#if !targetEnvironment(simulator)
        if case .ioQueue = diskCache?.fileFormat {
            self.ioCommandQueue = MetalIOCommandQueues.shared(for: device)
        } else {
            self.ioCommandQueue = nil
        }
#endif
        diskCache?.onIndexReady = { [weak self] in
            self?.requestFrame()
        }
    }

    /// Moves on every texture that arrives or leaves: with the coverage it
    /// is what the working set's placements are planned over.
    var contentVersion: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return version
    }

    /// How many bakes may start now: the frame's share less the ones still
    /// on the GPU, so a burst of new tiles never piles up bakes.
    var bakeCapacity: Int {
        lock.lock()
        defer { lock.unlock() }
        return max(0, bakesPerFrame - baking.count)
    }

    /// Diagnostics: what the textures on the GPU hold.
    var residentByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return residentBytes
    }

    /// One call per frame with the textures the frame wants, nearest
    /// first: the order the loads start in. Releases what passes the budget.
    func request(_ keys: [RasterTileKey]) -> Request {
        var availability: [RasterTileKey: Availability] = [:]
        var textures: [RasterTileKey: MTLTexture] = [:]
        var loads: [RasterTileKey] = []
        lock.lock()
        wanted = Set(keys)
        usageTick &+= 1
        var runningLoads = loading.count
        for key in keys where availability[key] == nil {
            if var entry = entries[key] {
                entry.lastUsedTick = usageTick
                entries[key] = entry
                availability[key] = .resident
                textures[key] = entry.texture
            } else if loading.contains(key) || baking.contains(key) {
                availability[key] = .pending
            } else {
                switch diskCache?.presence(of: key) ?? .absent {
                case .present:
                    // On disk: loading, or waiting for a load slot, which a
                    // load that ends frees with the frame it invalidates.
                    availability[key] = .pending
                    if runningLoads < Self.maximumConcurrentLoads {
                        runningLoads += 1
                        loading.insert(key)
                        loads.append(key)
                    }
                case .unknown:
                    // Not known yet whether it is on disk: a file there is
                    // not worth baking over.
                    availability[key] = .pending
                case .absent:
                    availability[key] = .needsBake
                }
            }
        }
        evictOverBudgetLocked()
        lock.unlock()
        for key in loads {
            startLoad(key)
        }
        return Request(availability: availability, textures: textures)
    }

    /// Draws the textures of `jobs` from their resident vector tiles, in
    /// one command buffer on the store's own queue: the frame never waits
    /// for it. Each texture lands when the GPU is done, and is written to
    /// disk then. The caller keeps to `bakeCapacity`.
    func bake(_ jobs: [(key: RasterTileKey, metalTile: MetalTile)]) {
        guard jobs.isEmpty == false,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        commandBuffer.label = "RasterTileBake"
        var baked: [(key: RasterTileKey, texture: MTLTexture, readback: MTLBuffer?)] = []
        for job in jobs {
            guard let texture = RasterTileLayout.makeTexture(device: device, size: job.key.size),
                  let multisampleTarget = multisampleTarget(size: job.key.size) else { continue }
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = multisampleTarget
            descriptor.colorAttachments[0].resolveTexture = texture
            descriptor.colorAttachments[0].resolveLevel = 0
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = clearColor
            descriptor.colorAttachments[0].storeAction = .multisampleResolve
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { continue }
            encoder.label = "RasterTileBake \(job.key.tile.z)/\(job.key.tile.x)/\(job.key.tile.y)"
            encoder.setRenderPipelineState(pipeline.bakePipelineState)
            encoder.setCullMode(.none)
            Self.encodeFills(of: job.metalTile.tileBuffers.ground, fadeZoom: job.key.fadeZoom, encoder: encoder)
            encoder.endEncoding()
            let readback = diskCache == nil
                ? nil
                : device.makeBuffer(length: RasterTileLayout.totalByteCount(size: job.key.size), options: .storageModeShared)
            baked.append((job.key, texture, readback))
        }
        guard baked.isEmpty == false else { return }
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "RasterTileMipmaps"
            for item in baked {
                blit.generateMipmaps(for: item.texture)
                guard let readback = item.readback else { continue }
                let offsets = RasterTileLayout.levelOffsets(size: item.key.size)
                for level in offsets.indices {
                    let edge = RasterTileLayout.edge(size: item.key.size, level: level)
                    blit.copy(from: item.texture,
                              sourceSlice: 0,
                              sourceLevel: level,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: edge, height: edge, depth: 1),
                              to: readback,
                              destinationOffset: offsets[level],
                              destinationBytesPerRow: RasterTileLayout.bytesPerRow(size: item.key.size, level: level),
                              destinationBytesPerImage: RasterTileLayout.levelByteCount(size: item.key.size, level: level))
                }
            }
            blit.endEncoding()
        }
        lock.lock()
        for item in baked {
            baking.insert(item.key)
        }
        lock.unlock()
        let results = baked.map { (key: $0.key, texture: TextureBox(texture: $0.texture), readback: $0.readback.map(BufferBox.init)) }
        commandBuffer.addCompletedHandler { [weak self] completed in
            guard let self else { return }
            let succeeded = completed.status == .completed
            for result in results {
                self.finishBake(result.key, texture: succeeded ? result.texture.texture : nil)
                if succeeded, let readback = result.readback?.buffer, let diskCache = self.diskCache {
                    let bytes = Data(bytes: readback.contents(), count: readback.length)
                    let key = result.key
                    DispatchQueue.global(qos: .utility).async {
                        diskCache.save(bytes, for: key)
                    }
                }
            }
            self.requestFrame()
        }
        commandBuffer.commit()
    }

    func handleMemoryWarning() {
        lock.lock()
        for key in entries.keys where wanted.contains(key) == false {
            releaseLocked(key)
        }
        multisampleTargets.removeAll()
        version &+= 1
        lock.unlock()
    }

    func evict() {
        lock.lock()
        entries.removeAll()
        residentBytes = 0
        multisampleTargets.removeAll()
        version &+= 1
        lock.unlock()
    }

    // MARK: - Bake

    private struct BufferBox: @unchecked Sendable {
        let buffer: MTLBuffer
    }

    /// The fill runs of a ground layer, in buffer order (bottom to top),
    /// adjacent runs in one draw. The ribbons are left out: the lines are
    /// never in a raster tile. The zoom fades are the camera's at
    /// `fadeZoom`: a run faded out there is left out, as the vector ground
    /// leaves it out, and the rest take their fade's alpha in the shader. A
    /// layer without a run table draws nothing, as the vector ground's
    /// class passes do.
    private static func encodeFills(of ground: TileBuffers.GeometryLayer,
                                    fadeZoom: Int,
                                    encoder: MTLRenderCommandEncoder) {
        guard ground.indicesCount > 0,
              let indices = ground.indices,
              let vertices = ground.vertices,
              let styles = ground.styles,
              let styleZoomFade = ground.styleZoomFade else { return }
        var fade = TileOverviewFadeUniform(pixelsPerPoint: 1, cameraZoom: Float(fadeZoom))
        encoder.setVertexBuffer(vertices.buffer, offset: vertices.offset, index: 0)
        encoder.setVertexBuffer(styles.buffer, offset: styles.offset, index: 2)
        encoder.setVertexBuffer(styleZoomFade.buffer, offset: styleZoomFade.offset, index: 4)
        encoder.setVertexBytes(&fade, length: MemoryLayout<TileOverviewFadeUniform>.stride, index: 11)
        let indexByteWidth = ground.indexType == .uint16 ? 2 : 4
        var spanStart = 0
        var spanCount = 0
        func flush() {
            guard spanCount > 0 else { return }
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: spanCount,
                                          indexType: ground.indexType,
                                          indexBuffer: indices.buffer,
                                          indexBufferOffset: indices.offset + spanStart * indexByteWidth)
            spanCount = 0
        }
        for run in ground.styleRuns {
            guard run.indexCount > 0,
                  run.isFillsClass,
                  TileStyleFadeMath.fadeIsZero(zoomFade: run.zoomFade, overviewFade: fade) == false else {
                flush()
                continue
            }
            if spanCount > 0, spanStart + spanCount == Int(run.indexStart) {
                spanCount += Int(run.indexCount)
            } else {
                flush()
                spanStart = Int(run.indexStart)
                spanCount = Int(run.indexCount)
            }
        }
        flush()
    }

    /// Main thread only, as `bake` is. Memoryless where the GPU keeps a
    /// pass's samples on chip: the samples live no longer than the pass.
    private func multisampleTarget(size: Int) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        if let target = multisampleTargets[size] {
            return target
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RasterTileLayout.pixelFormat,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: false)
        descriptor.textureType = .type2DMultisample
        descriptor.sampleCount = RasterTilePipeline.bakeSampleCount
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = device.supportsFamily(.apple2) ? .memoryless : .private
        let target = device.makeTexture(descriptor: descriptor)
        target?.label = "RasterTileBakeSamples.\(size)"
        multisampleTargets[size] = target
        return target
    }

    private func finishBake(_ key: RasterTileKey, texture: MTLTexture?) {
        lock.lock()
        baking.remove(key)
        if let texture {
            insertLocked(key, texture: texture)
        }
        lock.unlock()
    }

    // MARK: - Load

    private func startLoad(_ key: RasterTileKey) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let loaded = await self.loadFromDisk(key)
            self.finishLoad(key, texture: loaded?.texture)
            if loaded == nil {
                // Unreadable or gone: the file leaves, and the next frame
                // bakes the tile again.
                self.diskCache?.remove(key)
            }
            self.requestFrame()
        }
    }

    private func finishLoad(_ key: RasterTileKey, texture: MTLTexture?) {
        lock.lock()
        loading.remove(key)
        if let texture {
            insertLocked(key, texture: texture)
        }
        lock.unlock()
    }

    private func loadFromDisk(_ key: RasterTileKey) async -> TextureBox? {
        guard let diskCache,
              let texture = RasterTileLayout.makeTexture(device: device, size: key.size) else { return nil }
        switch diskCache.fileFormat {
        case .ioQueue(let format):
#if targetEnvironment(simulator)
            _ = format
            return nil
#else
            guard let ioCommandQueue else { return nil }
            let url = diskCache.fileURL(for: key)
            let fileHandle: MTLIOFileHandle?
            switch format {
            case .raw:
                fileHandle = try? device.makeIOFileHandle(url: url)
            case .lzfseContainer:
                fileHandle = try? device.makeIOFileHandle(url: url, compressionMethod: .lzfse)
            }
            guard let fileHandle else { return nil }
            let commandBuffer = ioCommandQueue.makeCommandBuffer()
            let offsets = RasterTileLayout.levelOffsets(size: key.size)
            for level in offsets.indices {
                let edge = RasterTileLayout.edge(size: key.size, level: level)
                commandBuffer.load(texture,
                                   slice: 0,
                                   level: level,
                                   size: MTLSize(width: edge, height: edge, depth: 1),
                                   sourceBytesPerRow: RasterTileLayout.bytesPerRow(size: key.size, level: level),
                                   sourceBytesPerImage: RasterTileLayout.levelByteCount(size: key.size, level: level),
                                   destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                                   sourceHandle: fileHandle,
                                   sourceHandleOffset: offsets[level])
            }
            let completed: Bool? = await CallbackTimeout.await(seconds: Self.fileLoadTimeout) { complete in
                commandBuffer.addCompletedHandler { completedBuffer in
                    complete(completedBuffer.status == .complete)
                }
                commandBuffer.commit()
            }
            if completed == nil {
                commandBuffer.tryCancel()
            }
            guard completed == true else { return nil }
            diskCache.markAccessed(key)
            return TextureBox(texture: texture)
#endif
        case .plain:
            guard let bytes = await diskCache.readBytes(for: key),
                  let staging = bytes.withUnsafeBytes({ raw in
                      raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: raw.count, options: .storageModeShared) }
                  }),
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
            let offsets = RasterTileLayout.levelOffsets(size: key.size)
            for level in offsets.indices {
                let edge = RasterTileLayout.edge(size: key.size, level: level)
                blit.copy(from: staging,
                          sourceOffset: offsets[level],
                          sourceBytesPerRow: RasterTileLayout.bytesPerRow(size: key.size, level: level),
                          sourceBytesPerImage: RasterTileLayout.levelByteCount(size: key.size, level: level),
                          sourceSize: MTLSize(width: edge, height: edge, depth: 1),
                          to: texture,
                          destinationSlice: 0,
                          destinationLevel: level,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
            blit.endEncoding()
            let completed: Bool? = await CallbackTimeout.await(seconds: Self.fileLoadTimeout) { complete in
                commandBuffer.addCompletedHandler { completedBuffer in
                    complete(completedBuffer.status == .completed)
                }
                commandBuffer.commit()
            }
            return completed == true ? TextureBox(texture: texture) : nil
        }
    }

    // MARK: - Residency

    private func insertLocked(_ key: RasterTileKey, texture: MTLTexture) {
        let byteCount = texture.allocatedSize > 0 ? texture.allocatedSize : RasterTileLayout.totalByteCount(size: key.size)
        if let replaced = entries.updateValue(Entry(texture: texture, byteCount: byteCount, lastUsedTick: usageTick),
                                              forKey: key) {
            residentBytes -= replaced.byteCount
        }
        residentBytes += byteCount
        version &+= 1
        evictOverBudgetLocked()
    }

    private func releaseLocked(_ key: RasterTileKey) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        residentBytes = max(0, residentBytes - removed.byteCount)
    }

    /// The longest unused textures the frame does not want leave until the
    /// rest fit the budget. Command buffers retain what they bind, so a
    /// texture a frame in flight draws stays until the GPU is done with it.
    private func evictOverBudgetLocked() {
        guard residentBytes > memoryBudgetInBytes else { return }
        let candidates = entries
            .filter { wanted.contains($0.key) == false }
            .sorted { $0.value.lastUsedTick < $1.value.lastUsedTick }
        for candidate in candidates where residentBytes > memoryBudgetInBytes {
            releaseLocked(candidate.key)
            version &+= 1
        }
    }

    private func requestFrame() {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?.invalidate(.tileAvailable)
        }
    }
}

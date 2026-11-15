// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import Metal

/// A layer on the GPU: its buffers and the chunks that draw from them
/// (`LayerMeshBuilder`). Immutable after creation, so it is shared between
/// the build that makes it and the frames that draw it (`@unchecked
/// Sendable`: Metal objects are safe to use from any thread, and nothing
/// here changes).
final class LayerMesh: @unchecked Sendable {
    /// How long a load from a mesh's file may take before the file is read
    /// the ordinary way instead.
    static let fileLoadTimeout: TimeInterval = 5

    let key: LayerMeshKey
    let fillVertices: MTLBuffer?
    let fillIndices: MTLBuffer?
    let lineSegments: MTLBuffer?
    let discs: MTLBuffer?
    let chunks: [LayerMeshChunk]

    private static let labels = ["Layer fill vertices", "Layer fill indices", "Layer line segments", "Layer discs"]

    init?(key: LayerMeshKey, data: LayerMeshData, device: MTLDevice) {
        func buffer<Element>(_ values: [Element], label: String) -> MTLBuffer? {
            guard values.isEmpty == false else { return nil }
            let buffer = values.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }
            buffer?.label = label
            return buffer
        }
        self.key = key
        fillVertices = buffer(data.fillVertices, label: Self.labels[0])
        fillIndices = buffer(data.fillIndices, label: Self.labels[1])
        lineSegments = buffer(data.lineSegments, label: Self.labels[2])
        discs = buffer(data.discs, label: Self.labels[3])
        chunks = data.chunks
        let complete = (data.fillIndices.isEmpty || (fillVertices != nil && fillIndices != nil))
            && (data.lineSegments.isEmpty || lineSegments != nil)
            && (data.discs.isEmpty || discs != nil)
        guard complete else { return nil }
    }

    private init(key: LayerMeshKey, chunks: [LayerMeshChunk], buffers: [MTLBuffer?]) {
        self.key = key
        self.chunks = chunks
        fillVertices = buffers[0]
        fillIndices = buffers[1]
        lineSegments = buffers[2]
        discs = buffers[3]
    }

    /// A mesh from its file on disk (`LayerMeshFile`): the blocks go
    /// straight from the file into the buffers through the device's IO
    /// queue, and are read the ordinary way where there is no such queue
    /// (the simulator, a device without Metal 3) or it does not answer.
    /// Nil for a file that is not a mesh of this version.
    static func load(key: LayerMeshKey, fileURL: URL, device: MTLDevice) async -> LayerMesh? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = (try? handle.seekToEnd()).map(Int.init),
              (try? handle.seek(toOffset: 0)) != nil,
              let header = try? handle.read(upToCount: LayerMeshFile.headerSize),
              let prefixSize = LayerMeshFile.prefixSize(ofHeader: header),
              prefixSize <= fileSize,
              (try? handle.seek(toOffset: 0)) != nil,
              let prefix = try? handle.read(upToCount: prefixSize),
              let contents = LayerMeshFile.decode(header: prefix, fileSize: fileSize) else {
            return nil
        }

        var buffers: [MTLBuffer?] = []
        for (range, label) in zip(contents.blocks, labels) {
            guard range.isEmpty == false else {
                buffers.append(nil)
                continue
            }
            guard let buffer = device.makeBuffer(length: range.count, options: .storageModeShared) else { return nil }
            buffer.label = label
            buffers.append(buffer)
        }

        var loaded = false
#if !targetEnvironment(simulator)
        if let queue = MetalIOCommandQueues.shared(for: device) {
            loaded = await load(contents.blocks, into: buffers, from: fileURL, device: device, queue: queue)
        }
#endif
        if loaded == false {
            for (range, buffer) in zip(contents.blocks, buffers) {
                guard let buffer else { continue }
                guard (try? handle.seek(toOffset: UInt64(range.lowerBound))) != nil,
                      let bytes = try? handle.read(upToCount: range.count), bytes.count == range.count else {
                    return nil
                }
                bytes.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: range.count) }
            }
        }
        return LayerMesh(key: key, chunks: contents.chunks, buffers: buffers)
    }

#if !targetEnvironment(simulator)
    /// The blocks loaded from the file by the device's IO queue, in one
    /// command buffer. False when the file could not be opened, the load
    /// ended in error, or the queue did not answer in time.
    private static func load(_ blocks: [Range<Int>],
                             into buffers: [MTLBuffer?],
                             from fileURL: URL,
                             device: MTLDevice,
                             queue: MTLIOCommandQueue) async -> Bool {
        guard let fileHandle = try? device.makeIOFileHandle(url: fileURL) else {
            return false
        }
        let commandBuffer = queue.makeCommandBuffer()
        for (range, buffer) in zip(blocks, buffers) {
            guard let buffer else { continue }
            commandBuffer.load(buffer,
                               offset: 0,
                               size: range.count,
                               sourceHandle: fileHandle,
                               sourceHandleOffset: range.lowerBound)
        }
        let completed: Bool? = await CallbackTimeout.await(seconds: fileLoadTimeout) { complete in
            commandBuffer.addCompletedHandler { completedBuffer in
                complete(completedBuffer.status == .complete)
            }
            commandBuffer.commit()
        }
        if completed == nil {
            // Best effort: the ordinary read that follows writes the same
            // bytes a late answer would.
            commandBuffer.tryCancel()
        }
        return completed == true
    }
#endif
}

/// Holds the layers of the app's data on the GPU for the frames. A layer
/// is prepared when a frame first draws it, off the main thread: from its
/// mesh on disk when it was prepared before (`LayerMeshDiskCache`), and otherwise from its source's shapes
/// (`LayerSourceLibrary`), which are read for it and whose mesh is then
/// kept on disk for the next time. A frame is asked for through
/// `eventSink` at each step. A layer whose source or styles changed
/// (`ImmersiveMapLayer.meshKey`) is prepared again, and the frames go on
/// drawing its last mesh until the new one is ready. A layer no longer set
/// is let go, and so is one that is not drawn when memory runs short
/// (`releaseUndrawn`). The state is serialized by a queue: the frames read
/// it on the main thread, the builds write it from theirs.
final class LayerMeshStore: @unchecked Sendable {
    private let device: MTLDevice
    private let queue = DispatchQueue(label: "ImmersiveMap.LayerMeshStore")
    private var meshes: [String: LayerMesh] = [:]
    /// The key each layer is being prepared for, from the disk or from
    /// its shapes.
    private var preparing: [String: LayerMeshKey] = [:]
    /// The keys the disk holds no mesh for: these are built from shapes.
    private var missedOnDisk: Set<LayerMeshKey> = []
    /// The ids of the layers the last frame drew.
    private var drawnIDs: Set<String> = []
    /// The library this store is a client of, the last frame's.
    private weak var library: LayerSourceLibrary?
    weak var eventSink: RenderFrameEventSink?

    init(device: MTLDevice) {
        self.device = device
    }

    deinit {
        library?.removeClient(self)
    }

    /// The meshes of `layers`, index-aligned with them, nil for a layer
    /// with none, and how many of the layers the frame draws are still on
    /// their way: their mesh being loaded, their source being read, their
    /// mesh being built, or drawn from the mesh of what they were before a
    /// change. `zoom` is the camera's: only the layers that draw at it are
    /// prepared. Lets go of the meshes of the layers no longer among
    /// `layers`. `contents` are the shapes of each layer's source, nil
    /// while they are not read.
    func meshes(for layers: [ImmersiveMapLayer],
                zoom: Double,
                library: LayerSourceLibrary?) -> (meshes: [LayerMesh?], contents: [LayerSourceContent?], pendingCount: Int) {
        observe(library)
        let drawn = layers.filter { $0.draws(atZoom: zoom) }
        var drawnSources: [String] = []
        for layer in drawn where drawnSources.contains(layer.source) == false {
            drawnSources.append(layer.source)
        }
        let allSources = Set(layers.map(\.source))
        // What the sources are, to know which layers are to be built from
        // shapes, then again with those named, which starts their reads.
        var states = library?.states(of: allSources, drawn: drawnSources, building: lastBuildingSources, client: self) ?? [:]
        let cache = library?.meshCache

        var toRestore: [(layer: ImmersiveMapLayer, key: LayerMeshKey, identity: LayerSourceIdentity)] = []
        var toBuild: [(layer: ImmersiveMapLayer, key: LayerMeshKey, content: LayerSourceContent, identity: LayerSourceIdentity)] = []
        var building: Set<String> = []
        var pendingCount = 0
        let result: [LayerMesh?] = queue.sync {
            let ids = Set(layers.map(\.id))
            meshes = meshes.filter { ids.contains($0.key) }
            preparing = preparing.filter { ids.contains($0.key) }
            drawnIDs = Set(drawn.map(\.id))
            return layers.map { layer in
                // A layer draws nothing when its source is not registered,
                // cannot be read or was refused for the limit.
                guard let state = states[layer.source], state.isFailed == false else {
                    meshes[layer.id] = nil
                    preparing[layer.id] = nil
                    return nil
                }
                let key = layer.meshKey(sourceRevision: state.revision)
                let mesh = meshes[layer.id]
                guard mesh?.key != key, drawnIDs.contains(layer.id) else {
                    return mesh
                }
                pendingCount += 1
                // The disk first.
                if cache?.isEnabled == true, missedOnDisk.contains(key) == false {
                    if preparing[layer.id] != key {
                        preparing[layer.id] = key
                        toRestore.append((layer, key, state.identity))
                    }
                    return mesh
                }
                building.insert(layer.source)
                if let content = state.content, preparing[layer.id] != key {
                    preparing[layer.id] = key
                    toBuild.append((layer, key, content, state.identity))
                }
                return mesh
            }
        }
        if building != lastBuildingSources {
            states = library?.states(of: allSources, drawn: drawnSources, building: building, client: self) ?? states
            lastBuildingSources = building
        }
        for item in toRestore {
            restore(item.layer, key: item.key, identity: item.identity, cache: cache)
        }
        for item in toBuild {
            build(item.layer, key: item.key, content: item.content, identity: item.identity, cache: cache)
        }
        return (result, layers.map { states[$0.source]?.content }, pendingCount)
    }

    /// The sources the last frame was building from, read on the main
    /// thread alone: the next frame names them again first, so their
    /// shapes are not let go between its two looks at the library.
    private var lastBuildingSources: Set<String> = []

    /// Lets go of the meshes of the layers the last frame did not draw,
    /// and of the shapes no map needs. Both come back when a frame draws
    /// the layer again.
    func releaseUndrawn() {
        queue.sync {
            meshes = meshes.filter { drawnIDs.contains($0.key) }
        }
        library?.releaseUnneeded()
    }

    /// Lets go of every mesh. The frames prepare again what they draw.
    func releaseAll() {
        queue.sync {
            meshes.removeAll()
            preparing.removeAll()
        }
    }

    private func observe(_ newLibrary: LayerSourceLibrary?) {
        guard library !== newLibrary else { return }
        library?.removeClient(self)
        library = newLibrary
        newLibrary?.addClient(self) { [weak self] in
            self?.eventSink?.invalidate(.layerDataLoaded)
        }
    }

    /// Loads the layer's mesh from the disk. A miss is remembered, and the
    /// next frame builds the layer from its shapes.
    private func restore(_ layer: ImmersiveMapLayer,
                         key: LayerMeshKey,
                         identity: LayerSourceIdentity,
                         cache: LayerMeshDiskCache?) {
        let device = device
        Task.detached(priority: .userInitiated) { [weak self] in
            var mesh: LayerMesh?
            if let cache, let name = cache.entryName(identity: identity, key: key),
               let meshFile = cache.existingFile(named: name) {
                mesh = await LayerMesh.load(key: key, fileURL: meshFile, device: device)
                if mesh == nil {
                    // Not a mesh of this version, or cut short: it is
                    // written anew by the build that follows.
                    cache.remove(named: name)
                }
            }
            guard let self else { return }
            self.queue.sync {
                guard self.preparing[layer.id] == key else { return }
                self.preparing[layer.id] = nil
                if let mesh {
                    self.meshes[layer.id] = mesh
                } else {
                    self.missedOnDisk.insert(key)
                }
            }
            self.eventSink?.invalidate(.layerDataLoaded)
        }
    }

    /// Builds the layer's mesh from its source's shapes, and keeps it on
    /// disk.
    private func build(_ layer: ImmersiveMapLayer,
                       key: LayerMeshKey,
                       content: LayerSourceContent,
                       identity: LayerSourceIdentity,
                       cache: LayerMeshDiskCache?) {
        let device = device
        Task.detached(priority: .userInitiated) { [weak self] in
            let data = LayerMeshBuilder.build(layer: layer, content: content)
            let mesh = LayerMesh(key: key, data: data, device: device)
            var kept = false
            if mesh != nil, let cache, cache.isEnabled,
               let name = cache.entryName(identity: identity, key: key) {
                cache.store(LayerMeshFile.encode(data), named: name)
                kept = true
            }
            guard let self else { return }
            let landed: Bool = self.queue.sync {
                // The disk has it now: the next time it is loaded from there.
                if kept {
                    self.missedOnDisk.remove(key)
                }
                guard self.preparing[layer.id] == key else { return false }
                self.preparing[layer.id] = nil
                if let mesh {
                    self.meshes[layer.id] = mesh
                }
                return mesh != nil
            }
            if landed {
                self.eventSink?.invalidate(.layerDataLoaded)
            }
        }
    }
}

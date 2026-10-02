// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import simd

enum ModelTileMeshError: Error, Equatable {
    case allocationFailed
}

/// A model tile on the GPU: one vertex buffer, one index buffer and one
/// texture array for every model of the tile. The vertices are in the
/// tile's space, so the frame binds each once, sets the tile's matrix, and
/// draws the merged models in one call.
///
/// Immutable after creation, so it is shared between the load that makes it
/// and the frames that draw it (`@unchecked Sendable`: Metal objects are
/// safe to use from any thread, and nothing here changes).
final class ModelTileMesh: @unchecked Sendable {
    /// A model that cuts into the ground: its place in the index buffer,
    /// for the draws of its own.
    struct GroundCutModel {
        let indexByteOffset: Int
        let indexCount: Int
    }

    let tile: Tile
    /// Every index of the tile: what the shadow casters draw.
    let indexCount: Int
    /// The indices from the first that draw in one call.
    let mergedIndexCount: Int
    /// The models after them, each drawn on its own.
    let groundCutModels: [GroundCutModel]
    /// The tile feature ids of the map buildings the tile's models stand
    /// in for, the ones the map's schema can name, by the zoom of the map
    /// tiles each list is for.
    let replacedBuildingIDs: [Int: Set<UInt64>]
    /// The bounds of the whole tile, in tile space.
    let boundsMinimum: SIMD3<Float>
    let boundsMaximum: SIMD3<Float>
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    /// The array of the tile's textures, one layer per source atlas.
    let texture: MTLTexture
    /// What the tile holds on the GPU, the cost the store budgets by.
    let costInBytes: Int

    /// Whether the device samples the textures a model tile carries. ASTC
    /// is on every Apple GPU, and absent from the Intel Macs' and from
    /// some simulators'.
    static func isSupported(device: MTLDevice) -> Bool {
        device.supportsFamily(.apple2)
    }

    /// How long a load from the tile's file may take before the bytes are
    /// copied from memory instead. A tile is a few megabytes and a healthy
    /// load ends in milliseconds, so this is reached only by a request the
    /// driver never answers.
    static let fileLoadTimeout: TimeInterval = 15

    /// Puts a decoded tile on the GPU and checks its geometry there.
    /// `data` is the bytes `contents` was decoded from. `schema` names the
    /// tile features of the replaced buildings.
    ///
    /// A tile from the disk cache comes with its file (`fileURL`): the
    /// vertex, index and texture blocks lie in it uncompressed and aligned,
    /// in the form the GPU takes, and the device's IO queue loads them from
    /// the file straight into the buffers and the texture, so the bulk of a
    /// tile never passes through the process's memory. `data` is then a
    /// mapping read only as far as the tables. A tile fresh from the
    /// archive is in memory already and is copied from there, as is a tile
    /// on a device without the IO queue (the simulator, a Mac without
    /// Metal 3), and one whose load from the file did not complete.
    static func make(contents: ModelTileContents,
                     data: Data,
                     fileURL: URL?,
                     device: MTLDevice,
                     schema: any ImmersiveMapTileSchema) async throws -> ModelTileMesh {
        guard let pixelFormat = Self.pixelFormat(blockEdge: contents.texture.blockEdge) else {
            throw ModelTileFormatError.malformed("the engine has no pixel format for ASTC \(contents.texture.blockEdge)x\(contents.texture.blockEdge)")
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = pixelFormat
        descriptor.width = contents.texture.width
        descriptor.height = contents.texture.height
        descriptor.arrayLength = contents.texture.layerCount
        descriptor.mipmapLevelCount = contents.texture.mipLevelCount
        descriptor.usage = [.shaderRead]
        // Shared memory is the GPU's own on the devices that have ASTC, so
        // the blocks are written once and no second copy is kept.
        descriptor.storageMode = .shared
        guard contents.vertexRange.isEmpty == false,
              contents.indexRange.isEmpty == false,
              let vertexBuffer = device.makeBuffer(length: contents.vertexRange.count, options: .storageModeShared),
              let indexBuffer = device.makeBuffer(length: contents.indexRange.count, options: .storageModeShared),
              let texture = device.makeTexture(descriptor: descriptor) else {
            throw ModelTileMeshError.allocationFailed
        }
        let name = "ModelTile \(contents.tile.z)/\(contents.tile.x)/\(contents.tile.y)"
        vertexBuffer.label = "\(name) vertices"
        indexBuffer.label = "\(name) indices"
        texture.label = "\(name) textures"

        var isLoaded = false
#if !targetEnvironment(simulator)
        if let fileURL, let queue = MetalIOCommandQueues.shared(for: device) {
            isLoaded = await load(contents: contents,
                                  from: fileURL,
                                  vertexBuffer: vertexBuffer,
                                  indexBuffer: indexBuffer,
                                  texture: texture,
                                  device: device,
                                  queue: queue)
        }
#endif
        if isLoaded == false {
            copy(contents: contents, from: data, vertexBuffer: vertexBuffer, indexBuffer: indexBuffer, texture: texture)
        }
        // Whichever way the blocks came, they are checked where the GPU
        // reads them.
        try contents.checkGeometry(vertices: UnsafeRawBufferPointer(start: vertexBuffer.contents(),
                                                                    count: contents.vertexRange.count),
                                   indices: UnsafeRawBufferPointer(start: indexBuffer.contents(),
                                                                   count: contents.indexRange.count))
        return ModelTileMesh(contents: contents,
                             vertexBuffer: vertexBuffer,
                             indexBuffer: indexBuffer,
                             texture: texture,
                             schema: schema)
    }

    private init(contents: ModelTileContents,
                 vertexBuffer: MTLBuffer,
                 indexBuffer: MTLBuffer,
                 texture: MTLTexture,
                 schema: any ImmersiveMapTileSchema) {
        self.tile = contents.tile
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.texture = texture
        self.costInBytes = contents.vertexRange.count + contents.indexRange.count + contents.textureRange.count
        self.indexCount = contents.indexCount
        self.mergedIndexCount = contents.mergedIndexCount
        self.boundsMinimum = contents.boundsMinimum
        self.boundsMaximum = contents.boundsMaximum
        self.groundCutModels = contents.models.filter(\.cutsIntoGround).map { model in
            GroundCutModel(indexByteOffset: model.firstIndex * MemoryLayout<UInt32>.stride,
                           indexCount: model.indexCount)
        }
        var replaced: [Int: Set<UInt64>] = [:]
        for model in contents.models {
            for entry in model.replacedBuildings {
                if let featureID = schema.tileFeatureID(of: entry.element) {
                    replaced[entry.mapTileZoom, default: []].insert(featureID)
                }
            }
        }
        self.replacedBuildingIDs = replaced
    }

    /// Each texture layer of each mip level with its place in the tile's
    /// bytes, in the order the texture block keeps them.
    private static func forEachTextureImage(of contents: ModelTileContents,
                                            _ body: (_ level: Int, _ layer: Int, _ size: MTLSize,
                                                     _ byteOffset: Int, _ bytesPerRow: Int, _ byteCount: Int) -> Void) {
        var offset = contents.textureRange.lowerBound
        for level in 0..<contents.texture.mipLevelCount {
            let layerByteCount = contents.texture.layerByteCount(level: level)
            let size = MTLSize(width: max(1, contents.texture.width >> level),
                               height: max(1, contents.texture.height >> level),
                               depth: 1)
            for layer in 0..<contents.texture.layerCount {
                body(level, layer, size, offset, contents.texture.bytesPerRow(level: level), layerByteCount)
                offset += layerByteCount
            }
        }
    }

    /// The blocks copied from the tile's bytes in memory.
    private static func copy(contents: ModelTileContents,
                             from data: Data,
                             vertexBuffer: MTLBuffer,
                             indexBuffer: MTLBuffer,
                             texture: MTLTexture) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            vertexBuffer.contents().copyMemory(from: base + contents.vertexRange.lowerBound,
                                               byteCount: contents.vertexRange.count)
            indexBuffer.contents().copyMemory(from: base + contents.indexRange.lowerBound,
                                              byteCount: contents.indexRange.count)
            forEachTextureImage(of: contents) { level, layer, size, byteOffset, bytesPerRow, byteCount in
                texture.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: size),
                                mipmapLevel: level,
                                slice: layer,
                                withBytes: base + byteOffset,
                                bytesPerRow: bytesPerRow,
                                bytesPerImage: byteCount)
            }
        }
    }

#if !targetEnvironment(simulator)
    /// The blocks loaded from the tile's file by the device's IO queue, in
    /// one command buffer. False when the file could not be opened, the
    /// load ended in error, or the queue did not answer in time.
    private static func load(contents: ModelTileContents,
                             from fileURL: URL,
                             vertexBuffer: MTLBuffer,
                             indexBuffer: MTLBuffer,
                             texture: MTLTexture,
                             device: MTLDevice,
                             queue: MTLIOCommandQueue) async -> Bool {
        guard let fileHandle = try? device.makeIOFileHandle(url: fileURL) else {
            return false
        }
        let commandBuffer = queue.makeCommandBuffer()
        commandBuffer.load(vertexBuffer,
                           offset: 0,
                           size: contents.vertexRange.count,
                           sourceHandle: fileHandle,
                           sourceHandleOffset: contents.vertexRange.lowerBound)
        commandBuffer.load(indexBuffer,
                           offset: 0,
                           size: contents.indexRange.count,
                           sourceHandle: fileHandle,
                           sourceHandleOffset: contents.indexRange.lowerBound)
        forEachTextureImage(of: contents) { level, layer, size, byteOffset, bytesPerRow, byteCount in
            commandBuffer.load(texture,
                               slice: layer,
                               level: level,
                               size: size,
                               sourceBytesPerRow: bytesPerRow,
                               sourceBytesPerImage: byteCount,
                               destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                               sourceHandle: fileHandle,
                               sourceHandleOffset: byteOffset)
        }
        let completed: Bool? = await CallbackTimeout.await(seconds: fileLoadTimeout) { complete in
            commandBuffer.addCompletedHandler { completedBuffer in
                complete(completedBuffer.status == .complete)
            }
            commandBuffer.commit()
        }
        if completed == nil {
            // Best effort: the copy from memory that follows writes the
            // same bytes a late answer would.
            commandBuffer.tryCancel()
        }
        return completed == true
    }
#endif

    private static func pixelFormat(blockEdge: Int) -> MTLPixelFormat? {
        switch blockEdge {
        case 4: return .astc_4x4_ldr
        case 5: return .astc_5x5_ldr
        case 6: return .astc_6x6_ldr
        case 8: return .astc_8x8_ldr
        case 10: return .astc_10x10_ldr
        case 12: return .astc_12x12_ldr
        default: return nil
        }
    }
}

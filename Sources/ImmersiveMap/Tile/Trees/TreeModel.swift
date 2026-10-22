// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import simd

enum TreeModelError: Error, Equatable {
    case malformed(String)
    case resourceMissing
    case allocationFailed
}

/// The tree model the woods and the parks stand
/// (`Resources/tree_broadleaf.immtree`), in the form the GPU reads it, so
/// the file is loaded into one buffer as it is and drawn from there
/// (`TreeModelMesh`). This comment is the format's reference.
///
/// The file is little-endian. A 24-byte header: the magic `IMTR`, the
/// format version (1), the count of levels of detail, the model's height
/// and its radius about the trunk in metres (two floats), and a reserved
/// word. Then one 16-byte entry per level, the near level first: the byte
/// offset and count of its vertices, the byte offset and count of its
/// indices, every offset from the file's start and 256-byte aligned, the
/// alignment a buffer offset needs on every GPU family (`blockAlignment`). The
/// geometry follows. A vertex is 20 bytes (`vertexStride`): the position
/// in metres, z up, the trunk's foot at the origin (three floats), the
/// unit normal as three signed bytes and a padding byte, and four bytes
/// of shading: how far up its part the point lies (0 at the crown's
/// underside or the trunk's foot, 255 at the top), whether the point is
/// on the trunk (255) or in the crown (0), and two reserved. The model
/// carries no colour: the frame colours it from the style
/// (`ImmersiveMapTreePalette`). The indices are 16-bit, three per
/// triangle, wound counter-clockwise seen from outside.
struct TreeModelContents: Sendable, Equatable {
    struct LevelOfDetail: Sendable, Equatable {
        let vertexOffset: Int
        let vertexCount: Int
        let indexOffset: Int
        let indexCount: Int
    }

    static let magic: [UInt8] = Array("IMTR".utf8)
    static let formatVersion: UInt32 = 1
    static let headerByteCount = 24
    static let levelEntryByteCount = 16
    static let vertexStride = 20
    static let indexStride = MemoryLayout<UInt16>.stride
    static let blockAlignment = 256

    /// The levels of detail, the near one first.
    let levels: [LevelOfDetail]
    let heightMetres: Float
    let radiusMetres: Float
    /// The whole file's size: what the buffer holds.
    let byteCount: Int

    /// Reads the tables of a model file and checks that every level's
    /// geometry lies within the file and every index names a vertex.
    static func read(_ data: Data) throws -> TreeModelContents {
        guard data.count >= headerByteCount else {
            throw TreeModelError.malformed("the file is shorter than its header")
        }
        let bytes = [UInt8](data)
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        guard Array(bytes[0..<4]) == magic else {
            throw TreeModelError.malformed("the file does not start with the magic")
        }
        guard word(4) == formatVersion else {
            throw TreeModelError.malformed("the file is of format version \(word(4)), the engine reads \(formatVersion)")
        }
        let levelCount = Int(word(8))
        guard levelCount >= 1, levelCount <= 8 else {
            throw TreeModelError.malformed("the file holds \(levelCount) levels of detail")
        }
        let heightMetres = Float(bitPattern: word(12))
        let radiusMetres = Float(bitPattern: word(16))
        guard heightMetres > 0, heightMetres.isFinite, radiusMetres >= 0, radiusMetres.isFinite else {
            throw TreeModelError.malformed("the model's size is not a positive number")
        }
        guard data.count >= headerByteCount + levelCount * levelEntryByteCount else {
            throw TreeModelError.malformed("the file is shorter than its level table")
        }
        var levels: [LevelOfDetail] = []
        for index in 0..<levelCount {
            let entry = headerByteCount + index * levelEntryByteCount
            let level = LevelOfDetail(vertexOffset: Int(word(entry)),
                                      vertexCount: Int(word(entry + 4)),
                                      indexOffset: Int(word(entry + 8)),
                                      indexCount: Int(word(entry + 12)))
            guard level.vertexCount > 0, level.vertexCount <= Int(UInt16.max) + 1,
                  level.indexCount > 0, level.indexCount % 3 == 0,
                  level.vertexOffset % blockAlignment == 0, level.indexOffset % blockAlignment == 0,
                  level.vertexOffset + level.vertexCount * vertexStride <= data.count,
                  level.indexOffset + level.indexCount * indexStride <= data.count else {
                throw TreeModelError.malformed("level \(index) lies outside the file")
            }
            for indexPosition in 0..<level.indexCount {
                let offset = level.indexOffset + indexPosition * indexStride
                let vertex = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                guard vertex < level.vertexCount else {
                    throw TreeModelError.malformed("level \(index) names vertex \(vertex) of \(level.vertexCount)")
                }
            }
            levels.append(level)
        }
        return TreeModelContents(levels: levels,
                                 heightMetres: heightMetres,
                                 radiusMetres: radiusMetres,
                                 byteCount: data.count)
    }
}

/// The tree model on the GPU: the file in one buffer, drawn by the levels'
/// offsets into it. Immutable after creation (`@unchecked Sendable`: Metal
/// objects are safe to use from any thread, and nothing here changes).
final class TreeModelMesh: @unchecked Sendable {
    let contents: TreeModelContents
    let buffer: MTLBuffer

    /// How long a load from the file may take before the bytes are copied
    /// from memory instead: the file is a few kilobytes, so this is
    /// reached only by a request the driver never answers.
    static let fileLoadTimeout: TimeInterval = 15

    /// Puts the model file on the GPU: by the device's IO queue straight
    /// from the file where there is one, else copied from `data`.
    static func make(contents: TreeModelContents,
                     data: Data,
                     fileURL: URL,
                     device: MTLDevice) async throws -> TreeModelMesh {
        guard let buffer = device.makeBuffer(length: contents.byteCount, options: .storageModeShared) else {
            throw TreeModelError.allocationFailed
        }
        buffer.label = "TreeModel"
        var isLoaded = false
#if !targetEnvironment(simulator)
        if let queue = MetalIOCommandQueues.shared(for: device),
           let fileHandle = try? device.makeIOFileHandle(url: fileURL) {
            let commandBuffer = queue.makeCommandBuffer()
            commandBuffer.load(buffer, offset: 0, size: contents.byteCount, sourceHandle: fileHandle, sourceHandleOffset: 0)
            let completed: Bool? = await CallbackTimeout.await(seconds: fileLoadTimeout) { complete in
                commandBuffer.addCompletedHandler { completedBuffer in
                    complete(completedBuffer.status == .complete)
                }
                commandBuffer.commit()
            }
            if completed == nil {
                commandBuffer.tryCancel()
            }
            isLoaded = completed == true
        }
#endif
        if isLoaded == false {
            data.withUnsafeBytes { bytes in
                buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: min(bytes.count, contents.byteCount))
            }
        }
        return TreeModelMesh(contents: contents, buffer: buffer)
    }

    private init(contents: TreeModelContents, buffer: MTLBuffer) {
        self.contents = contents
        self.buffer = buffer
    }
}

/// Holds the engine's tree model for the frames: loaded once, off the main
/// thread, from the package's resources, and asked for every frame. The
/// frames before it lands draw no trees, and its landing asks for a frame
/// through `eventSink`, as a map tile does.
final class TreeModelStore: @unchecked Sendable {
    static let resourceName = "tree_broadleaf"
    static let resourceExtension = "immtree"

    private let lock = NSLock()
    private var loadedMesh: TreeModelMesh?
    private weak var sink: RenderFrameEventSink?

    weak var eventSink: RenderFrameEventSink? {
        get { lock.withLock { sink } }
        set { lock.withLock { sink = newValue } }
    }

    /// The model, nil until it has landed.
    var mesh: TreeModelMesh? {
        lock.withLock { loadedMesh }
    }

    init(device: MTLDevice) {
        Task.detached(priority: .utility) { [self] in
            await load(device: device)
        }
    }

    private func load(device: MTLDevice) async {
        guard let url = Bundle.module.url(forResource: Self.resourceName, withExtension: Self.resourceExtension) else {
            assertionFailure("The tree model is missing from the package resources")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let contents = try TreeModelContents.read(data)
            let mesh = try await TreeModelMesh.make(contents: contents, data: data, fileURL: url, device: device)
            lock.withLock { loadedMesh = mesh }
            eventSink?.invalidate(.sceneModelAssetLoaded)
        } catch {
            assertionFailure("The tree model could not be loaded: \(error)")
        }
    }
}

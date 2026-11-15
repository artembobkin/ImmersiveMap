// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// A layer's mesh as it is kept on disk (`LayerMeshDiskCache`): a header,
/// the table of its chunks, and its five blocks exactly as the GPU takes
/// them, so a file is loaded straight into the buffers with nothing to
/// parse. Little-endian, as every device the engine runs on.
///
/// The layout, `version` 4:
///
///     magic "IMLM"            4 bytes
///     version                 UInt32
///     chunk count             UInt32
///     4 x (offset, size)      UInt64 each: fill vertices, fill indices,
///                             line segments, discs
///     chunks                  `chunkStride` bytes each
///     blocks                  each at a multiple of 16 bytes
///
/// A change to this layout, to a GPU struct or to what `LayerMeshBuilder`
/// makes of a shape is a new `version`: the files of an older one are then
/// misses and are written anew. Version 2 made every line solid, version 3
/// gave a segment round ends in place of a disc at each join, and version
/// 4 keeps a line as one instance per segment.
enum LayerMeshFile {
    static let version: UInt32 = 4
    static let magic: [UInt8] = Array("IMLM".utf8)
    static let blockCount = 4
    static let headerSize = 12 + blockCount * 16
    static let chunkStride = 3 * 4 + 8 * 4 + 5 * 4

    /// Where the blocks lie in a file, and the chunks that draw from them.
    struct Contents: Equatable {
        var chunks: [LayerMeshChunk]
        var fillVertices: Range<Int>
        var fillIndices: Range<Int>
        var lineSegments: Range<Int>
        var discs: Range<Int>

        var blocks: [Range<Int>] { [fillVertices, fillIndices, lineSegments, discs] }
    }

    static func encode(_ mesh: LayerMeshData) -> Data {
        func bytes<Element>(_ values: [Element]) -> Data {
            values.withUnsafeBytes { Data($0) }
        }
        let blocks = [bytes(mesh.fillVertices), bytes(mesh.fillIndices), bytes(mesh.lineSegments), bytes(mesh.discs)]
        var offset = headerSize + mesh.chunks.count * chunkStride
        var ranges: [Range<Int>] = []
        for block in blocks {
            offset = (offset + 15) / 16 * 16
            ranges.append(offset ..< offset + block.count)
            offset += block.count
        }

        var data = Data(capacity: offset)
        data.append(contentsOf: magic)
        data.append(version)
        data.append(UInt32(mesh.chunks.count))
        for range in ranges {
            data.append(UInt64(range.lowerBound))
            data.append(UInt64(range.count))
        }
        for chunk in mesh.chunks {
            for value in [chunk.tile.x, chunk.tile.y, chunk.tile.z] {
                data.append(Int32(value))
            }
            for value in [chunk.fillIndexStart, chunk.fillIndexCount, chunk.lineStart, chunk.lineCount,
                          chunk.joinStart, chunk.joinCount, chunk.pointStart, chunk.pointCount] {
                data.append(UInt32(value))
            }
            for value in [chunk.boundsMinimum.x, chunk.boundsMinimum.y, chunk.boundsMaximum.x, chunk.boundsMaximum.y,
                          chunk.maximumReachPoints] {
                data.append(value.bitPattern)
            }
        }
        for (block, range) in zip(blocks, ranges) {
            data.append(Data(count: range.lowerBound - data.count))
            data.append(block)
        }
        return data
    }

    /// Reads the header and the chunks of a file of `fileSize` bytes from
    /// its first bytes. Nil for a file of another version, a cut one, or
    /// one whose blocks do not hold what its chunks draw.
    static func decode(header data: Data, fileSize: Int) -> Contents? {
        var reader = Reader(data: data)
        guard reader.bytes(4) == magic,
              reader.read(UInt32.self) == version,
              let chunkCount = reader.read(UInt32.self).map(Int.init) else {
            return nil
        }
        var ranges: [Range<Int>] = []
        for _ in 0 ..< blockCount {
            guard let offset = reader.read(UInt64.self), let size = reader.read(UInt64.self),
                  offset <= UInt64(fileSize), size <= UInt64(fileSize) - offset else {
                return nil
            }
            ranges.append(Int(offset) ..< Int(offset + size))
        }
        var chunks: [LayerMeshChunk] = []
        chunks.reserveCapacity(chunkCount)
        for _ in 0 ..< chunkCount {
            guard let x = reader.read(Int32.self), let y = reader.read(Int32.self), let z = reader.read(Int32.self) else {
                return nil
            }
            var counts: [Int] = []
            for _ in 0 ..< 8 {
                guard let value = reader.read(UInt32.self) else { return nil }
                counts.append(Int(value))
            }
            var floats: [Float] = []
            for _ in 0 ..< 5 {
                guard let value = reader.read(UInt32.self) else { return nil }
                floats.append(Float(bitPattern: value))
            }
            chunks.append(LayerMeshChunk(tile: Tile(x: Int(x), y: Int(y), z: Int(z)),
                                         fillIndexStart: counts[0], fillIndexCount: counts[1],
                                         lineStart: counts[2], lineCount: counts[3],
                                         joinStart: counts[4], joinCount: counts[5],
                                         pointStart: counts[6], pointCount: counts[7],
                                         boundsMinimum: SIMD2(floats[0], floats[1]),
                                         boundsMaximum: SIMD2(floats[2], floats[3]),
                                         maximumReachPoints: floats[4]))
        }
        let contents = Contents(chunks: chunks, fillVertices: ranges[0], fillIndices: ranges[1],
                                lineSegments: ranges[2], discs: ranges[3])
        // A chunk never draws past the end of a block: a damaged file must
        // not send the GPU out of its buffers.
        let fillIndexCount = contents.fillIndices.count / MemoryLayout<UInt32>.stride
        let lineCount = contents.lineSegments.count / MemoryLayout<LayerLineSegment>.stride
        let discCount = contents.discs.count / MemoryLayout<LayerPointInstance>.stride
        for chunk in chunks {
            guard chunk.fillIndexStart + chunk.fillIndexCount <= fillIndexCount,
                  chunk.lineStart + chunk.lineCount <= lineCount,
                  chunk.joinStart + chunk.joinCount <= discCount,
                  chunk.pointStart + chunk.pointCount <= discCount else {
                return nil
            }
        }
        return contents
    }

    /// How many bytes from a file's start hold its header and its chunks,
    /// given its first `headerSize` bytes. Nil when they are not a header.
    static func prefixSize(ofHeader data: Data) -> Int? {
        var reader = Reader(data: data)
        guard reader.bytes(4) == magic, reader.read(UInt32.self) == version,
              let chunkCount = reader.read(UInt32.self), chunkCount < 1 << 24 else {
            return nil
        }
        return headerSize + Int(chunkCount) * chunkStride
    }

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func bytes(_ count: Int) -> [UInt8]? {
            guard offset + count <= data.count else { return nil }
            defer { offset += count }
            return Array(data[data.startIndex + offset ..< data.startIndex + offset + count])
        }

        mutating func read<Value: FixedWidthInteger>(_: Value.Type) -> Value? {
            guard let bytes = bytes(MemoryLayout<Value>.size) else { return nil }
            var value: Value = 0
            for (index, byte) in bytes.enumerated() {
                value |= Value(truncatingIfNeeded: byte) << Value(index * 8)
            }
            return value
        }
    }
}

private extension Data {
    mutating func append<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import PMTiles
import zlib

/// Writes a PMTiles v3 archive the way the specification describes it, so a
/// test states an archive as tiles and options and the bytes travel the real
/// reader. The reader never sees this code: its own varint writer, header
/// serialiser and Hilbert id keep the round trip a check against the
/// specification rather than against the reader.
package struct PMTilesArchiveWriter {
    package struct Tile: Equatable {
        package var z: Int
        package var x: Int
        package var y: Int
        package var data: Data

        package init(z: Int, x: Int, y: Int, data: Data) {
            self.z = z
            self.x = x
            self.y = y
            self.data = data
        }
    }

    package var tiles: [Tile] = []
    /// An explicit directory in place of one derived from `tiles`, for a
    /// run-length fixture. Offsets and lengths are relative to `tileData`.
    package var explicitEntries: [PMTilesEntry]?
    /// The tile data section used with `explicitEntries`.
    package var explicitTileData: Data?
    package var tileCompression: PMTilesCompression = .gzip
    package var internalCompression: PMTilesCompression = .gzip
    /// A root directory with more entries than this is split into leaves.
    package var maximumRootEntries = 16_384
    package var minZoom: UInt8 = 0
    package var maxZoom: UInt8 = 15
    package var metadata = Data("{}".utf8)
    package var isClustered = true

    package init() {}

    package func serializedData() -> Data {
        var tileData = Data()
        var entries: [PMTilesEntry] = []

        if let explicitEntries {
            entries = explicitEntries
            tileData = explicitTileData ?? Data()
        } else {
            var offsetsByContent: [Data: (offset: UInt64, length: UInt32)] = [:]
            var sortedTiles: [(id: UInt64, data: Data)] = tiles.map { tile in
                (Self.tileID(z: tile.z, x: tile.x, y: tile.y), tile.data)
            }
            sortedTiles.sort { $0.id < $1.id }
            for tile in sortedTiles {
                let stored = compress(tile.data, compression: tileCompression)
                let location: (offset: UInt64, length: UInt32)
                if let existing = offsetsByContent[stored] {
                    location = existing
                } else {
                    location = (UInt64(tileData.count), UInt32(stored.count))
                    tileData.append(stored)
                    offsetsByContent[stored] = location
                }
                entries.append(PMTilesEntry(tileID: tile.id,
                                            offset: location.offset,
                                            length: location.length,
                                            runLength: 1))
            }
        }

        // Directories: the root points at leaves when the entry list is too
        // long for one root.
        var leafData = Data()
        let rootEntries: [PMTilesEntry]
        if entries.count > maximumRootEntries {
            var pointers: [PMTilesEntry] = []
            var start = 0
            while start < entries.count {
                let end = min(entries.count, start + maximumRootEntries)
                let leaf = compress(Self.encodeDirectory(Array(entries[start..<end])),
                                    compression: internalCompression)
                pointers.append(PMTilesEntry(tileID: entries[start].tileID,
                                             offset: UInt64(leafData.count),
                                             length: UInt32(leaf.count),
                                             runLength: 0))
                leafData.append(leaf)
                start = end
            }
            rootEntries = pointers
        } else {
            rootEntries = entries
        }
        let rootData = compress(Self.encodeDirectory(rootEntries), compression: internalCompression)
        let metadataData = compress(metadata, compression: internalCompression)

        let headerLength = 127
        let rootOffset = UInt64(headerLength)
        let metadataOffset = rootOffset + UInt64(rootData.count)
        let leafOffset = metadataOffset + UInt64(metadataData.count)
        let tileDataOffset = leafOffset + UInt64(leafData.count)

        var header = Data()
        header.append(contentsOf: Array("PMTiles".utf8))
        header.append(3)
        Self.appendUInt64(&header, rootOffset)
        Self.appendUInt64(&header, UInt64(rootData.count))
        Self.appendUInt64(&header, metadataOffset)
        Self.appendUInt64(&header, UInt64(metadataData.count))
        Self.appendUInt64(&header, leafOffset)
        Self.appendUInt64(&header, UInt64(leafData.count))
        Self.appendUInt64(&header, tileDataOffset)
        Self.appendUInt64(&header, UInt64(tileData.count))
        let addressed = entries.reduce(UInt64(0)) { $0 + UInt64(max(1, $1.runLength)) }
        Self.appendUInt64(&header, addressed)
        Self.appendUInt64(&header, UInt64(entries.count))
        Self.appendUInt64(&header, UInt64(Set(entries.map { $0.offset }).count))
        header.append(isClustered ? 1 : 0)
        header.append(internalCompression.rawValue)
        header.append(tileCompression.rawValue)
        header.append(PMTilesTileType.mvt.rawValue)
        header.append(minZoom)
        header.append(maxZoom)
        Self.appendInt32(&header, -180_0000000)
        Self.appendInt32(&header, -85_0000000)
        Self.appendInt32(&header, 180_0000000)
        Self.appendInt32(&header, 85_0000000)
        header.append(0)
        Self.appendInt32(&header, 0)
        Self.appendInt32(&header, 0)
        precondition(header.count == headerLength)

        var archive = header
        archive.append(rootData)
        archive.append(metadataData)
        archive.append(leafData)
        archive.append(tileData)
        return archive
    }

    // MARK: - Encoding

    package static func encodeDirectory(_ entries: [PMTilesEntry]) -> Data {
        var data = Data()
        appendVarint(&data, UInt64(entries.count))
        var lastID: UInt64 = 0
        for entry in entries {
            appendVarint(&data, entry.tileID - lastID)
            lastID = entry.tileID
        }
        for entry in entries {
            appendVarint(&data, UInt64(entry.runLength))
        }
        for entry in entries {
            appendVarint(&data, UInt64(entry.length))
        }
        for (index, entry) in entries.enumerated() {
            if index > 0,
               entry.offset == entries[index - 1].offset + UInt64(entries[index - 1].length) {
                appendVarint(&data, 0)
            } else {
                appendVarint(&data, entry.offset + 1)
            }
        }
        return data
    }

    package static func appendVarint(_ data: inout Data, _ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    private static func appendUInt64(_ data: inout Data, _ value: UInt64) {
        for index in 0..<8 {
            data.append(UInt8((value >> (8 * UInt64(index))) & 0xFF))
        }
    }

    private static func appendInt32(_ data: inout Data, _ value: Int32) {
        let bits = UInt32(bitPattern: value)
        for index in 0..<4 {
            data.append(UInt8((bits >> (8 * UInt32(index))) & 0xFF))
        }
    }

    /// The Hilbert tile id, written independently of the reader's.
    package static func tileID(z: Int, x: Int, y: Int) -> UInt64 {
        var accumulator: UInt64 = 0
        var zoom = 0
        while zoom < z {
            accumulator += UInt64(1) << UInt64(2 * zoom)
            zoom += 1
        }
        let n = UInt64(1) << UInt64(z)
        var rx: UInt64 = 0
        var ry: UInt64 = 0
        var d: UInt64 = 0
        var tx = UInt64(x)
        var ty = UInt64(y)
        var s = n / 2
        while s > 0 {
            rx = (tx & s) > 0 ? 1 : 0
            ry = (ty & s) > 0 ? 1 : 0
            d += s * s * ((3 * rx) ^ ry)
            if ry == 0 {
                if rx == 1 {
                    tx = n - 1 - tx
                    ty = n - 1 - ty
                }
                let temporary = tx
                tx = ty
                ty = temporary
            }
            s /= 2
        }
        return accumulator + d
    }

    private func compress(_ data: Data, compression: PMTilesCompression) -> Data {
        switch compression {
        case .gzip:
            return Self.gzip(data)
        default:
            return data
        }
    }

    /// A gzip member with a file name field, so the reader is checked
    /// against the optional header fields and not only the minimal member.
    package static func gzip(_ data: Data, fileName: String? = nil) -> Data {
        var stream = z_stream()
        let status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                                   Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        precondition(status == Z_OK)
        defer { deflateEnd(&stream) }

        if let fileName {
            var header = gz_header()
            var nameBytes = Array(fileName.utf8) + [0]
            nameBytes.withUnsafeMutableBufferPointer { buffer in
                header.name = buffer.baseAddress
                header.name_max = UInt32(buffer.count)
                _ = deflateSetHeader(&stream, &header)
            }
        }

        var input = [UInt8](data)
        let bound = Int(deflateBound(&stream, UInt(input.count))) + 64
        var output = [UInt8](repeating: 0, count: bound)
        var produced = 0
        input.withUnsafeMutableBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                stream.next_in = inputBuffer.baseAddress
                stream.avail_in = UInt32(inputBuffer.count)
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = UInt32(outputBuffer.count)
                let result = deflate(&stream, Z_FINISH)
                precondition(result == Z_STREAM_END)
                produced = outputBuffer.count - Int(stream.avail_out)
            }
        }
        return Data(output[0..<produced])
    }
}

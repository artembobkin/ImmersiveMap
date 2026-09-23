// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// How the directories and the tiles are compressed inside the archive.
package enum PMTilesCompression: UInt8, Sendable, Equatable {
    case unknown = 0
    case none = 1
    case gzip = 2
    case brotli = 3
    case zstd = 4
}

/// What a tile's bytes are. The engine reads Mapbox Vector Tiles only.
package enum PMTilesTileType: UInt8, Sendable, Equatable {
    case unknown = 0
    case mvt = 1
    case png = 2
    case jpeg = 3
    case webp = 4
    case avif = 5
}

/// The 127-byte header at the start of every v3 archive: where the root
/// directory, the leaf directories and the tile data sit, how each is
/// compressed, and the zoom range the archive covers. All integers are
/// little-endian. The header and the root directory both fit in the first
/// `initialFetchByteCount` bytes, so one range request answers both.
package struct PMTilesHeader: Sendable, Equatable {
    package static let byteCount = 127
    package static let initialFetchByteCount = 16_384
    package static let magic: [UInt8] = Array("PMTiles".utf8)

    package var rootDirectoryOffset: UInt64
    package var rootDirectoryLength: UInt64
    package var metadataOffset: UInt64
    package var metadataLength: UInt64
    package var leafDirectoriesOffset: UInt64
    package var leafDirectoriesLength: UInt64
    package var tileDataOffset: UInt64
    package var tileDataLength: UInt64
    package var addressedTileCount: UInt64
    package var tileEntryCount: UInt64
    package var tileContentCount: UInt64
    package var isClustered: Bool
    package var internalCompression: PMTilesCompression
    package var tileCompression: PMTilesCompression
    package var tileType: PMTilesTileType
    package var minZoom: UInt8
    package var maxZoom: UInt8
    /// Degrees, from the header's 1e-7 fixed-point integers.
    package var minLongitude: Double
    package var minLatitude: Double
    package var maxLongitude: Double
    package var maxLatitude: Double
    package var centerZoom: UInt8
    package var centerLongitude: Double
    package var centerLatitude: Double

    /// Reads the header from the first bytes of an archive. Rejects anything
    /// the engine cannot read: another version, brotli or zstd, a raster
    /// tile type. `data` may be longer than the header.
    package init(parsing data: Data) throws {
        guard data.count >= Self.byteCount else {
            throw PMTilesFormatError.truncated
        }
        let bytes = [UInt8](data.prefix(Self.byteCount))
        guard Array(bytes[0..<7]) == Self.magic else {
            throw PMTilesFormatError.badMagic
        }
        guard bytes[7] == 3 else {
            throw PMTilesFormatError.unsupportedVersion(bytes[7])
        }

        func uint64(at offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<8 {
                value |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
            }
            return value
        }
        func int32(at offset: Int) -> Int32 {
            var value: UInt32 = 0
            for index in 0..<4 {
                value |= UInt32(bytes[offset + index]) << (8 * UInt32(index))
            }
            return Int32(bitPattern: value)
        }
        func compression(at offset: Int) throws -> PMTilesCompression {
            guard let value = PMTilesCompression(rawValue: bytes[offset]),
                  value == .none || value == .gzip else {
                throw PMTilesFormatError.unsupportedCompression(bytes[offset])
            }
            return value
        }

        rootDirectoryOffset = uint64(at: 8)
        rootDirectoryLength = uint64(at: 16)
        metadataOffset = uint64(at: 24)
        metadataLength = uint64(at: 32)
        leafDirectoriesOffset = uint64(at: 40)
        leafDirectoriesLength = uint64(at: 48)
        tileDataOffset = uint64(at: 56)
        tileDataLength = uint64(at: 64)
        addressedTileCount = uint64(at: 72)
        tileEntryCount = uint64(at: 80)
        tileContentCount = uint64(at: 88)
        isClustered = bytes[96] == 1
        internalCompression = try compression(at: 97)
        tileCompression = try compression(at: 98)
        guard let type = PMTilesTileType(rawValue: bytes[99]), type == .mvt else {
            throw PMTilesFormatError.unsupportedTileType(bytes[99])
        }
        tileType = type
        minZoom = bytes[100]
        maxZoom = bytes[101]
        minLongitude = Double(int32(at: 102)) / 10_000_000
        minLatitude = Double(int32(at: 106)) / 10_000_000
        maxLongitude = Double(int32(at: 110)) / 10_000_000
        maxLatitude = Double(int32(at: 114)) / 10_000_000
        centerZoom = bytes[118]
        centerLongitude = Double(int32(at: 119)) / 10_000_000
        centerLatitude = Double(int32(at: 123)) / 10_000_000
    }

    /// The byte range of the root directory inside the archive.
    package var rootDirectoryRange: Range<UInt64> {
        rootDirectoryOffset..<(rootDirectoryOffset + rootDirectoryLength)
    }

    /// Where a leaf directory entry's bytes sit in the archive.
    package func leafDirectoryRange(for entry: PMTilesEntry) -> Range<UInt64> {
        let start = leafDirectoriesOffset + entry.offset
        return start..<(start + UInt64(entry.length))
    }

    /// Where a tile entry's bytes sit in the archive.
    package func tileDataRange(for entry: PMTilesEntry) -> Range<UInt64> {
        let start = tileDataOffset + entry.offset
        return start..<(start + UInt64(entry.length))
    }
}

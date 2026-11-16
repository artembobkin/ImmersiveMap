// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// What stops an archive from being written.
public enum PMTilesWriterError: Error, Equatable, Sendable, CustomStringConvertible {
    case noTiles
    /// The tile's coordinates lie outside its zoom's grid.
    case tileOutsideItsZoom(zoom: Int, x: Int, y: Int)
    /// The tile is larger than this module's reader takes
    /// (`PMTilesWriter.maximumTileByteCount`).
    case tileTooLarge(zoom: Int, x: Int, y: Int, byteCount: Int)
    /// The root directory does not fit in the bytes a reader fetches first.
    /// Leaf directories are not written.
    case rootDirectoryTooLarge(byteCount: Int)
    case compressionFailed

    public var description: String {
        switch self {
        case .noTiles:
            return "no tiles to write"
        case .tileOutsideItsZoom(let zoom, let x, let y):
            return "tile \(zoom)/\(x)/\(y) lies outside its zoom"
        case .tileTooLarge(let zoom, let x, let y, let byteCount):
            return "tile \(zoom)/\(x)/\(y) is \(byteCount) bytes, and a reader takes a tile up to \(PMTilesWriter.maximumTileByteCount)"
        case .rootDirectoryTooLarge(let byteCount):
            return "the root directory is \(byteCount) bytes and does not fit in the first \(PMTilesHeader.initialFetchByteCount) with the header, and leaf directories are not written"
        case .compressionFailed:
            return "zlib could not write a gzip stream"
        }
    }
}

/// Writes a PMTiles v3 archive this module's reader reads: clustered, with
/// one root directory, gzip for the directory, the metadata and the tiles.
/// The tile type is the specification's "unknown": the payload is whatever
/// the caller's tiles are, as an archive of the engine's model tiles is.
///
/// Public, alone in this module: the baker of a model archive lives in
/// another package and writes its archive with it, on the header, the tile
/// id and the limits the reader itself goes by.
public struct PMTilesWriter {
    public struct Tile {
        public var zoom: Int
        public var x: Int
        public var y: Int
        /// The tile's bytes, not compressed.
        public var data: Data

        public init(zoom: Int, x: Int, y: Int, data: Data) {
            self.zoom = zoom
            self.x = x
            self.y = y
            self.data = data
        }
    }

    /// The largest tile, not compressed, the reader takes: it holds a
    /// larger one to be a corrupt length. A baker checks its tiles against
    /// this before it writes them.
    public static let maximumTileByteCount = PMTilesGzip.maximumOutputByteCount

    public var tiles: [Tile] = []
    /// The archive's metadata, written as JSON.
    public var metadata: [String: Any] = [:]

    public init() {}

    public func serialized() throws -> Data {
        guard tiles.isEmpty == false else {
            throw PMTilesWriterError.noTiles
        }
        let sorted = try tiles
            .map { tile -> (id: UInt64, tile: Tile) in
                guard let id = PMTilesTileID.id(z: tile.zoom, x: tile.x, y: tile.y) else {
                    throw PMTilesWriterError.tileOutsideItsZoom(zoom: tile.zoom, x: tile.x, y: tile.y)
                }
                guard tile.data.count <= Self.maximumTileByteCount else {
                    throw PMTilesWriterError.tileTooLarge(zoom: tile.zoom, x: tile.x, y: tile.y, byteCount: tile.data.count)
                }
                return (id, tile)
            }
            .sorted { $0.id < $1.id }

        // The directory, column by column: the ids as differences, the run
        // lengths, the lengths, the offsets.
        var tileData = Data()
        var directory = Data()
        PMTilesVarint.append(UInt64(sorted.count), to: &directory)
        var lastID: UInt64 = 0
        for entry in sorted {
            PMTilesVarint.append(entry.id - lastID, to: &directory)
            lastID = entry.id
        }
        for _ in sorted {
            PMTilesVarint.append(1, to: &directory)
        }
        var compressedTiles: [Data] = []
        for entry in sorted {
            let compressed = try PMTilesGzip.deflate(entry.tile.data)
            compressedTiles.append(compressed)
            PMTilesVarint.append(UInt64(compressed.count), to: &directory)
        }
        for (index, compressed) in compressedTiles.enumerated() {
            // Zero says the tile follows the one before it. Otherwise the
            // offset is stored plus one.
            PMTilesVarint.append(index == 0 ? UInt64(tileData.count) + 1 : 0, to: &directory)
            tileData.append(compressed)
        }

        let root = try PMTilesGzip.deflate(directory)
        guard PMTilesHeader.byteCount + root.count <= PMTilesHeader.initialFetchByteCount else {
            throw PMTilesWriterError.rootDirectoryTooLarge(byteCount: root.count)
        }
        let metadataData = try PMTilesGzip.deflate(try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]))

        let zooms = tiles.map(\.zoom)
        var west = 180.0
        var south = 90.0
        var east = -180.0
        var north = -90.0
        for tile in tiles {
            let bounds = Self.bounds(zoom: tile.zoom, x: tile.x, y: tile.y)
            west = min(west, bounds.west)
            south = min(south, bounds.south)
            east = max(east, bounds.east)
            north = max(north, bounds.north)
        }

        let rootOffset = UInt64(PMTilesHeader.byteCount)
        let metadataOffset = rootOffset + UInt64(root.count)
        let leafOffset = metadataOffset + UInt64(metadataData.count)
        let tileDataOffset = leafOffset

        var header = Data(PMTilesHeader.magic)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        append(UInt8(3))
        append(rootOffset)
        append(UInt64(root.count))
        append(metadataOffset)
        append(UInt64(metadataData.count))
        append(leafOffset)
        append(UInt64(0))
        append(tileDataOffset)
        append(UInt64(tileData.count))
        // Addressed tiles, tile entries, tile contents: one each per tile.
        append(UInt64(sorted.count))
        append(UInt64(sorted.count))
        append(UInt64(sorted.count))
        // Clustered, then how the directories and the tiles are compressed,
        // then what a tile is.
        append(UInt8(1))
        append(PMTilesCompression.gzip.rawValue)
        append(PMTilesCompression.gzip.rawValue)
        append(PMTilesTileType.unknown.rawValue)
        append(UInt8(zooms.min() ?? 0))
        append(UInt8(zooms.max() ?? 0))
        append(Self.fixedPoint(west))
        append(Self.fixedPoint(south))
        append(Self.fixedPoint(east))
        append(Self.fixedPoint(north))
        append(UInt8(zooms.max() ?? 0))
        append(Self.fixedPoint((west + east) / 2))
        append(Self.fixedPoint((south + north) / 2))
        precondition(header.count == PMTilesHeader.byteCount)

        var archive = header
        archive.append(root)
        archive.append(metadataData)
        archive.append(tileData)
        return archive
    }

    /// Degrees as the header stores them: an integer of 1e-7 degrees.
    private static func fixedPoint(_ degrees: Double) -> Int32 {
        Int32((degrees * 10_000_000).rounded())
    }

    /// The edges of a tile in degrees, for the bounds the header states.
    private static func bounds(zoom: Int, x: Int, y: Int) -> (west: Double, south: Double, east: Double, north: Double) {
        let tilesAcross = Double(1 << zoom)
        func longitude(_ column: Int) -> Double {
            Double(column) / tilesAcross * 360 - 180
        }
        func latitude(_ row: Int) -> Double {
            atan(sinh(.pi * (1 - 2 * Double(row) / tilesAcross))) * 180 / .pi
        }
        return (longitude(x), latitude(y + 1), longitude(x + 1), latitude(y))
    }
}

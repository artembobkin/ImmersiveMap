// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import simd

// The `ModelTileFormat` module: the model tile as bytes, read
// (`ModelTileContents`) and written (`ModelTile`, `ModelTileVertex`), one
// place for the layout, its version and its reference, which the engine
// and the baker of the archives both link. It knows nothing of the engine,
// of Metal or of where a model comes from: Foundation and simd alone.

/// What can be wrong with the bytes of a model tile. Every case names the
/// place it was found, so a tile baked by another version of the baker is
/// diagnosable from the message alone.
public enum ModelTileFormatError: Error, Equatable, Sendable {
    case truncated
    case badMagic
    case unsupportedVersion(UInt32)
    case unsupportedVertexStride(UInt32)
    case malformed(String)
}

/// A model tile, decoded: every model whose origin lies in one map tile,
/// merged into one mesh, with the places of the tile's vertex, index and
/// texture blocks in the bytes. One vertex buffer, one index buffer and one
/// texture array serve the whole tile and every vertex is in the tile's own
/// space, so the frame draws the whole tile in one call under the tile's
/// matrix.
///
/// Tile space is the space the map's own buildings are in: X east and Y
/// north from the tile's south-west corner, `tileExtent` units to a tile
/// edge, Z up from the ground in the same units. A model reaching over the
/// tile's edge has coordinates outside that range. It is not cut.
///
/// The format, version 6. This comment is its reference: the archives are
/// baked outside this repository, by the baker of the project the models
/// are made in, which writes a tile with this module's `ModelTile`.
///
/// All integers and floats are little-endian. The blocks follow the header
/// in the order below. The vertex, index and texture blocks each start on a
/// multiple of `blockAlignment` bytes, and the tile ends on one, so a tile mapped
/// from the disk cache hands each block to Metal without a copy.
///
/// Header, `headerByteCount` bytes:
///
///     0   4 bytes  magic "IMMT"
///     4   u32      version, 6
///     8   u32 x 3  tile zoom, x, y
///     20  u32      model count
///     24  u32      vertex count
///     28  u32      index count
///     32  u32      vertex stride, 16
///     36  u32      texture layer count
///     40  u32 x 2  texture width, height of mip level 0
///     48  u32      texture mip level count
///     52  u32      ASTC block edge: 8 means 8x8
///     56  u32 x 2  model table offset, byte count
///     64  u32 x 2  string block offset, byte count
///     72  u32 x 2  vertex block offset, byte count
///     80  u32 x 2  index block offset, byte count
///     88  u32 x 2  texture block offset, byte count
///     96  u32 x 2  replaced building block offset, byte count
///     104 u32      reserved, 0
///     108 u32      reserved, 0
///     112 f32 x 3  minimum of the tile's bounding box, tile space
///     124 f32 x 3  maximum of the tile's bounding box, tile space
///
/// Model table, `modelRecordByteCount` bytes per model:
///
///     0   f64 x 2  latitude, longitude of the model's origin, degrees
///     16  f32      altitude of the origin above the map surface, meters,
///                  already in the vertices
///     20  u32 x 2  the buildings the model replaces, in the replaced
///                  building block: first entry, entry count
///     28  u32      reserved, 0
///     32  u32 x 2  the model's id in the string block: offset, byte count
///     40  u32 x 2  first index, index count
///     48  u32 x 2  first vertex, vertex count
///     56  f32 x 3  minimum of the model's bounding box, tile space
///     68  f32 x 3  maximum of the model's bounding box, tile space
///     80  u32      reserved, 0
///
/// String block: the ids, UTF-8, one after another.
///
/// Replaced building block, `replacedBuildingEntryByteCount` bytes per
/// entry: a feature of the map's own tiles a model stands in for, in the
/// map tiles of one zoom.
///
///     0   u64      the element: its kind in the top four bits (1 node,
///                  2 way, 3 relation) and its OSM id in the rest
///     8   u32      the zoom of the map tiles the entry is for
///     12  u32      reserved, 0
///
/// An id names a building only within a zoom. The deepest map tiles carry
/// one feature per OSM element. The tiles above them merge buildings into
/// groups, and a group goes by the id of one of its members: there the
/// same id is a group of buildings, most of them elsewhere. So a model
/// lists what it replaces zoom by zoom, and the map hides in a tile only
/// the entries of that tile's zoom. A model lists every feature the map
/// would draw in its place: the map hides exactly the ids it is given.
///
/// Vertex, `vertexStride` bytes:
///
///     0   u16 x 3  position, unsigned normalized across the tile's
///                  bounding box
///     6   u16 x 2  texture coordinate, unsigned normalized, V down
///     10  i8 x 3   normal, signed normalized, tile space
///     13  u8       texture layer
///     14  u16      reserved, 0
///
/// A position is a place in the tile's bounding box, the header's: 0 on an
/// axis is the box's minimum there and 65535 its maximum, so a position in
/// tile space is `minimum + stored / 65535 * (maximum - minimum)`
/// (`positionMatrix`). Across a tile of zoom 14 with the models reaching
/// over its edges a step is two to three centimeters on the ground, and
/// finer in height. The stride is a multiple of four bytes, which some
/// GPUs ask of a vertex. Version 5 kept a position as three floats in a
/// vertex of 20 bytes.
///
/// Index block: `u32` triangle list, counter-clockwise front faces seen
/// from outside. An index counts from the start of the tile's vertex block.
///
/// Texture block: ASTC LDR blocks with no file header, raw channel values
/// (no sRGB decode). Mip level 0 first: all layers of a level, layer 0
/// first, then the next level. A level of `w` by `h` pixels takes
/// `ceil(w / edge) * ceil(h / edge) * 16` bytes per layer.
public struct ModelTileContents: Equatable, Sendable {
    /// The zoom of the map tiles a model archive holds: a map asks for
    /// model tiles of this zoom alone, whatever zoom it is at, and a baker
    /// writes these.
    public static let tileZoom = 14
    public static let magic: [UInt8] = Array("IMMT".utf8)
    public static let version: UInt32 = 6
    public static let replacedBuildingEntryByteCount = 16
    public static let headerByteCount = 136
    /// The units of tile space along a tile's edge, the map's own extent.
    public static let tileExtent: Float = 4096
    /// The bits of a replaced building entry the element's kind sits above.
    public static let replacedBuildingKindShift: UInt64 = 60
    public static let modelRecordByteCount = 84
    public static let vertexStride = 16
    /// The byte offsets inside a vertex.
    public static let textureCoordinateOffset = 6
    public static let normalOffset = 10
    public static let layerOffset = 13
    /// What the vertex, index and texture blocks each start on a multiple
    /// of, and the tile ends on: a page of the devices' memory.
    public static let blockAlignment = 16_384

    /// A feature of the map's tiles a model stands in for, in the map tiles
    /// of one zoom: an id names a building only within a zoom.
    public struct ReplacedBuilding: Equatable, Sendable {
        public var element: ModelTileElement
        public var mapTileZoom: Int

        public init(element: ModelTileElement, mapTileZoom: Int) {
            self.element = element
            self.mapTileZoom = mapTileZoom
        }
    }

    public struct Model: Equatable, Sendable {
        public var id: String
        /// The features of the map's own tiles the model stands in for,
        /// each in the map tiles of one zoom: the building's outline and
        /// its parts in the deepest tiles, the groups they are merged into
        /// above. The map leaves out exactly these. Empty for a model that
        /// stands where the map has no building.
        public var replacedBuildings: [ReplacedBuilding]
        public var firstIndex: Int
        public var indexCount: Int
        /// In tile space.
        public var boundsMinimum: SIMD3<Float>
        public var boundsMaximum: SIMD3<Float>
    }

    public struct Texture: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var mipLevelCount: Int
        /// The edge of an ASTC block in pixels: 8 for 8x8.
        public var blockEdge: Int
        public var layerCount: Int

        public init(width: Int, height: Int, mipLevelCount: Int, blockEdge: Int, layerCount: Int) {
            self.width = width
            self.height = height
            self.mipLevelCount = mipLevelCount
            self.blockEdge = blockEdge
            self.layerCount = layerCount
        }

        /// The bytes one layer takes at a mip level.
        public func layerByteCount(level: Int) -> Int {
            let levelWidth = max(1, width >> level)
            let levelHeight = max(1, height >> level)
            return blocksAcross(levelWidth) * blocksAcross(levelHeight) * 16
        }

        /// The bytes of one row of blocks at a mip level.
        public func bytesPerRow(level: Int) -> Int {
            blocksAcross(max(1, width >> level)) * 16
        }

        /// The bytes of the whole array: every layer of every level.
        public var byteCount: Int {
            (0..<mipLevelCount).reduce(0) { $0 + layerByteCount(level: $1) * layerCount }
        }

        private func blocksAcross(_ pixels: Int) -> Int {
            (pixels + blockEdge - 1) / blockEdge
        }
    }

    /// The map tile the models' origins lie in.
    public var zoom: Int
    public var x: Int
    public var y: Int
    public var models: [Model]
    public var vertexCount: Int
    public var indexCount: Int
    /// The bounds of every vertex of the tile, in tile space.
    public var boundsMinimum: SIMD3<Float>
    public var boundsMaximum: SIMD3<Float>
    public var texture: Texture
    /// The places of the blocks in the tile's bytes.
    public var vertexRange: Range<Int>
    public var indexRange: Range<Int>
    public var textureRange: Range<Int>

    /// A stored position, 0...1 on each axis across the tile's bounding
    /// box, into tile space: the box's minimum and its size. A draw takes
    /// it after the tile's own matrix, so the vertices stay as the tile
    /// wrote them.
    public var positionMatrix: matrix_float4x4 {
        let size = boundsMaximum - boundsMinimum
        return matrix_float4x4(columns: (SIMD4<Float>(size.x, 0, 0, 0),
                                         SIMD4<Float>(0, size.y, 0, 0),
                                         SIMD4<Float>(0, 0, size.z, 0),
                                         SIMD4<Float>(boundsMinimum.x, boundsMinimum.y, boundsMinimum.z, 1)))
    }

    /// Reads a tile's header and tables and checks what they say: the
    /// blocks lie inside the bytes and the models' ranges inside the
    /// blocks. It reads the first bytes of the tile only, so a tile mapped
    /// from the disk is not paged in whole. The vertices and indices
    /// themselves are checked once they are in their buffers
    /// (`checkGeometry`).
    public init(decoding data: Data) throws {
        guard data.count >= Self.headerByteCount else {
            throw ModelTileFormatError.truncated
        }
        var reader = Reader(data: data)
        guard reader.bytes(count: 4) == Self.magic else {
            throw ModelTileFormatError.badMagic
        }
        let version = reader.uint32()
        guard version == Self.version else {
            throw ModelTileFormatError.unsupportedVersion(version)
        }
        let zoom = Int(reader.uint32())
        let x = Int(reader.uint32())
        let y = Int(reader.uint32())
        let modelCount = Int(reader.uint32())
        let vertexCount = Int(reader.uint32())
        let indexCount = Int(reader.uint32())
        let stride = reader.uint32()
        guard stride == UInt32(Self.vertexStride) else {
            throw ModelTileFormatError.unsupportedVertexStride(stride)
        }
        let layerCount = Int(reader.uint32())
        let width = Int(reader.uint32())
        let height = Int(reader.uint32())
        let mipLevelCount = Int(reader.uint32())
        let blockEdge = Int(reader.uint32())

        func block(_ name: String) throws -> Range<Int> {
            let offset = Int(reader.uint32())
            let byteCount = Int(reader.uint32())
            guard offset >= Self.headerByteCount, offset + byteCount <= data.count else {
                throw ModelTileFormatError.malformed("the \(name) block lies outside the tile")
            }
            return offset..<(offset + byteCount)
        }
        let tableRange = try block("model table")
        let stringRange = try block("string")
        let vertexRange = try block("vertex")
        let indexRange = try block("index")
        let textureRange = try block("texture")
        let replacedRange = try block("replaced building")
        // Reserved.
        _ = reader.uint32()
        _ = reader.uint32()
        let boundsMinimum = SIMD3<Float>(reader.float32(), reader.float32(), reader.float32())
        let boundsMaximum = SIMD3<Float>(reader.float32(), reader.float32(), reader.float32())

        guard zoom <= 24, x < 1 << zoom, y < 1 << zoom else {
            throw ModelTileFormatError.malformed("the tile coordinate is outside its zoom")
        }
        guard tableRange.count == modelCount * Self.modelRecordByteCount,
              vertexRange.count == vertexCount * Self.vertexStride,
              indexRange.count == indexCount * MemoryLayout<UInt32>.stride,
              replacedRange.count % Self.replacedBuildingEntryByteCount == 0,
              indexCount % 3 == 0 else {
            throw ModelTileFormatError.malformed("a block's byte count disagrees with its element count")
        }
        let texture = Texture(width: width, height: height, mipLevelCount: mipLevelCount,
                              blockEdge: blockEdge, layerCount: layerCount)
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              layerCount > 0, layerCount <= 256,
              [4, 5, 6, 8, 10, 12].contains(blockEdge),
              mipLevelCount > 0, mipLevelCount <= Int(log2(Double(max(width, height)))) + 1,
              texture.byteCount == textureRange.count else {
            throw ModelTileFormatError.malformed("the texture description disagrees with the texture block")
        }

        // The replaced buildings of every model, one after another.
        var replacedElements: [ReplacedBuilding] = []
        replacedElements.reserveCapacity(replacedRange.count / Self.replacedBuildingEntryByteCount)
        reader.offset = replacedRange.lowerBound
        for _ in 0..<(replacedRange.count / Self.replacedBuildingEntryByteCount) {
            let entry = reader.uint64()
            let mapTileZoom = Int(reader.uint32())
            _ = reader.uint32()
            let id = entry & (1 << Self.replacedBuildingKindShift - 1)
            guard let element = ModelTileElement(kind: entry >> Self.replacedBuildingKindShift, id: id) else {
                throw ModelTileFormatError.malformed("a replaced building is an element of an unknown kind")
            }
            guard mapTileZoom <= 24 else {
                throw ModelTileFormatError.malformed("a replaced building is listed for a zoom no map tile has")
            }
            replacedElements.append(ReplacedBuilding(element: element, mapTileZoom: mapTileZoom))
        }

        guard boundsMinimum.x.isFinite, boundsMinimum.y.isFinite, boundsMinimum.z.isFinite,
              boundsMaximum.x.isFinite, boundsMaximum.y.isFinite, boundsMaximum.z.isFinite else {
            throw ModelTileFormatError.malformed("the tile's bounds are not numbers")
        }

        var models: [Model] = []
        models.reserveCapacity(modelCount)
        reader.offset = tableRange.lowerBound
        for _ in 0..<modelCount {
            let latitude = reader.float64()
            let longitude = reader.float64()
            let altitudeMeters = reader.float32()
            let firstReplaced = Int(reader.uint32())
            let replacedCount = Int(reader.uint32())
            _ = reader.uint32()
            let idOffset = Int(reader.uint32())
            let idByteCount = Int(reader.uint32())
            let firstIndex = Int(reader.uint32())
            let modelIndexCount = Int(reader.uint32())
            let firstVertex = Int(reader.uint32())
            let modelVertexCount = Int(reader.uint32())
            let boundsMinimum = SIMD3<Float>(reader.float32(), reader.float32(), reader.float32())
            let boundsMaximum = SIMD3<Float>(reader.float32(), reader.float32(), reader.float32())
            _ = reader.uint32()

            guard idOffset + idByteCount <= stringRange.count,
                  let id = String(data: data.subdata(in: (data.startIndex + stringRange.lowerBound + idOffset)
                                                     ..< (data.startIndex + stringRange.lowerBound + idOffset + idByteCount)),
                                  encoding: .utf8) else {
                throw ModelTileFormatError.malformed("a model's id lies outside the string block")
            }
            guard firstIndex + modelIndexCount <= indexCount,
                  firstVertex + modelVertexCount <= vertexCount,
                  modelIndexCount % 3 == 0 else {
                throw ModelTileFormatError.malformed("model \(id) reaches outside the tile's vertices or indices")
            }
            guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180,
                  altitudeMeters.isFinite,
                  boundsMinimum.x.isFinite, boundsMinimum.y.isFinite, boundsMinimum.z.isFinite,
                  boundsMaximum.x.isFinite, boundsMaximum.y.isFinite, boundsMaximum.z.isFinite else {
                throw ModelTileFormatError.malformed("model \(id) has a placement that is not a number")
            }
            guard firstReplaced + replacedCount <= replacedElements.count else {
                throw ModelTileFormatError.malformed("model \(id) reaches outside the replaced buildings")
            }
            models.append(Model(id: id,
                                replacedBuildings: Array(replacedElements[firstReplaced..<(firstReplaced + replacedCount)]),
                                firstIndex: firstIndex,
                                indexCount: modelIndexCount,
                                boundsMinimum: boundsMinimum,
                                boundsMaximum: boundsMaximum))
        }

        self.zoom = zoom
        self.x = x
        self.y = y
        self.models = models
        self.vertexCount = vertexCount
        self.indexCount = indexCount
        self.boundsMinimum = boundsMinimum
        self.boundsMaximum = boundsMaximum
        self.texture = texture
        self.vertexRange = vertexRange
        self.indexRange = indexRange
        self.textureRange = textureRange
    }

    /// Checks the tile's vertex and index blocks, given as they lie in the
    /// tile: an index past the vertices or a layer past the texture array
    /// would have the GPU read what is not there. Run on the buffers the
    /// blocks were loaded into, before the tile draws.
    public func checkGeometry(vertices: UnsafeRawBufferPointer, indices: UnsafeRawBufferPointer) throws {
        guard vertices.count == vertexRange.count, indices.count == indexRange.count else {
            throw ModelTileFormatError.truncated
        }
        var offset = 0
        while offset < indices.count {
            if Int(UInt32(littleEndian: indices.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) >= vertexCount {
                throw ModelTileFormatError.malformed("an index names a vertex past the vertex block")
            }
            offset += MemoryLayout<UInt32>.stride
        }
        offset = Self.layerOffset
        while offset < vertices.count {
            if Int(vertices[offset]) >= texture.layerCount {
                throw ModelTileFormatError.malformed("a vertex names a texture layer past the texture array")
            }
            offset += Self.vertexStride
        }
    }

    /// Reads little-endian values in order. The caller has checked that the
    /// bytes it reads exist.
    private struct Reader {
        let data: Data
        var offset = 0

        mutating func bytes(count: Int) -> [UInt8] {
            defer { offset += count }
            return [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
        }

        mutating func integer<T: FixedWidthInteger>(_ type: T.Type) -> T {
            defer { offset += MemoryLayout<T>.size }
            return data.withUnsafeBytes { bytes in
                T(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: T.self))
            }
        }

        mutating func uint8() -> UInt8 { integer(UInt8.self) }
        mutating func uint16() -> UInt16 { integer(UInt16.self) }
        mutating func uint32() -> UInt32 { integer(UInt32.self) }
        mutating func uint64() -> UInt64 { integer(UInt64.self) }
        mutating func float32() -> Float { Float(bitPattern: integer(UInt32.self)) }
        mutating func float64() -> Double { Double(bitPattern: integer(UInt64.self)) }
    }
}

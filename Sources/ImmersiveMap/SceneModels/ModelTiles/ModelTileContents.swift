// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// What can be wrong with the bytes of a model tile. Every case names the
/// place it was found, so a tile baked by another version of the baker is
/// diagnosable from the message alone.
enum ModelTileFormatError: Error, Equatable {
    case truncated
    case badMagic
    case unsupportedVersion(UInt32)
    case unsupportedVertexStride(UInt32)
    case malformed(String)
}

/// A model tile, decoded: every model whose origin lies in one map tile,
/// merged into one mesh, with the places of the tile's vertex, index and
/// texture blocks in the bytes. One vertex buffer, one index buffer and one
/// texture array serve the whole tile, every vertex is in the tile's own
/// space, and the models that take no state of their own come first in the
/// indices, so the frame draws them all in one call under the tile's
/// matrix.
///
/// Tile space is the space the map's own buildings are in: X east and Y
/// north from the tile's south-west corner, `tileExtent` units to a tile
/// edge, Z up from the ground in the same units. A model reaching over the
/// tile's edge has coordinates outside that range. It is not cut.
///
/// The format, version 4. This comment is its reference: the archives are
/// baked outside this repository, by the baker of the project the models
/// are made in, which writes what is described here.
///
/// All integers and floats are little-endian. The blocks follow the header
/// in the order below. The vertex, index and texture blocks each start on a
/// multiple of 16384 bytes, and the tile ends on one, so a tile mapped
/// from the disk cache hands each block to Metal without a copy.
///
/// Header, `headerByteCount` bytes:
///
///     0   4 bytes  magic "IMMT"
///     4   u32      version, 4
///     8   u32 x 3  tile zoom, x, y
///     20  u32      model count
///     24  u32      vertex count
///     28  u32      index count
///     32  u32      vertex stride, 20
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
///     104 u32      merged index count: the indices from the first that
///                  draw in one call
///     108 u32      reserved, 0
///     112 f32 x 3  minimum of the tile's bounding box, tile space
///     124 f32 x 3  maximum of the tile's bounding box, tile space
///
/// Model table, `modelRecordByteCount` bytes per model. The models whose
/// indices are merged come first, then the ones that cut into the ground,
/// which the map draws one by one:
///
///     0   f64 x 2  latitude, longitude of the model's origin, degrees
///     16  f32      altitude of the origin above the map surface, meters,
///                  already in the vertices
///     20  u32      flags: bit 0, the model cuts into the ground
///     24  u32 x 2  the buildings the model replaces, in the replaced
///                  building block: first entry, entry count
///     32  u32      reserved, 0
///     36  u32 x 2  the model's id in the string block: offset, byte count
///     44  u32 x 2  first index, index count
///     52  u32 x 2  first vertex, vertex count
///     60  f32 x 3  minimum of the model's bounding box, tile space
///     72  f32 x 3  maximum of the model's bounding box, tile space
///     84  u32      reserved, 0
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
///     0   f32 x 3  position, tile space
///     12  i8 x 3   normal, signed normalized, tile space
///     15  u8       texture layer
///     16  u16 x 2  texture coordinate, unsigned normalized, V down
///
/// Index block: `u32` triangle list, counter-clockwise front faces seen
/// from outside. An index counts from the start of the tile's vertex block.
///
/// Texture block: ASTC LDR blocks with no file header, raw channel values
/// (no sRGB decode). Mip level 0 first: all layers of a level, layer 0
/// first, then the next level. A level of `w` by `h` pixels takes
/// `ceil(w / edge) * ceil(h / edge) * 16` bytes per layer.
struct ModelTileContents: Equatable {
    static let magic: [UInt8] = Array("IMMT".utf8)
    static let version: UInt32 = 4
    static let replacedBuildingEntryByteCount = 16
    static let headerByteCount = 136
    /// The units of tile space along a tile's edge, the map's own extent.
    static let tileExtent: Float = 4096
    /// The bits of a replaced building entry the element's kind sits above.
    static let replacedBuildingKindShift: UInt64 = 60
    static let modelRecordByteCount = 88
    static let vertexStride = 20
    /// The byte offsets inside a vertex.
    static let normalOffset = 12
    static let layerOffset = 15
    static let textureCoordinateOffset = 16

    /// A feature of the map's tiles a model stands in for, in the map tiles
    /// of one zoom: an id names a building only within a zoom, see
    /// `ReplacedBuildings`.
    struct ReplacedBuilding: Equatable {
        var element: ImmersiveMapOSMElement
        var mapTileZoom: Int
    }

    struct Model: Equatable {
        var id: String
        /// See `ImmersiveMapSceneModel.cutsIntoGround`. Such a model's
        /// indices follow the merged ones, and it is drawn on its own.
        var cutsIntoGround: Bool
        /// The features of the map's own tiles the model stands in for,
        /// each in the map tiles of one zoom: the building's outline and
        /// its parts in the deepest tiles, the groups they are merged into
        /// above. The map leaves out exactly these. Empty for a model that
        /// stands where the map has no building.
        var replacedBuildings: [ReplacedBuilding]
        var firstIndex: Int
        var indexCount: Int
        /// In tile space.
        var boundsMinimum: SIMD3<Float>
        var boundsMaximum: SIMD3<Float>
    }

    struct Texture: Equatable {
        var width: Int
        var height: Int
        var mipLevelCount: Int
        /// The edge of an ASTC block in pixels: 8 for 8x8.
        var blockEdge: Int
        var layerCount: Int

        /// The bytes one layer takes at a mip level.
        func layerByteCount(level: Int) -> Int {
            let levelWidth = max(1, width >> level)
            let levelHeight = max(1, height >> level)
            return blocksAcross(levelWidth) * blocksAcross(levelHeight) * 16
        }

        /// The bytes of one row of blocks at a mip level.
        func bytesPerRow(level: Int) -> Int {
            blocksAcross(max(1, width >> level)) * 16
        }

        /// The bytes of the whole array: every layer of every level.
        var byteCount: Int {
            (0..<mipLevelCount).reduce(0) { $0 + layerByteCount(level: $1) * layerCount }
        }

        private func blocksAcross(_ pixels: Int) -> Int {
            (pixels + blockEdge - 1) / blockEdge
        }
    }

    var tile: Tile
    var models: [Model]
    var vertexCount: Int
    var indexCount: Int
    /// The indices from the first that draw in one call: every model that
    /// does not cut into the ground.
    var mergedIndexCount: Int
    /// The bounds of every vertex of the tile, in tile space.
    var boundsMinimum: SIMD3<Float>
    var boundsMaximum: SIMD3<Float>
    var texture: Texture
    /// The places of the blocks in the tile's bytes.
    var vertexRange: Range<Int>
    var indexRange: Range<Int>
    var textureRange: Range<Int>

    /// Reads a tile's header and tables and checks what they say: the
    /// blocks lie inside the bytes and the models' ranges inside the
    /// blocks. It reads the first bytes of the tile only, so a tile mapped
    /// from the disk is not paged in whole. The vertices and indices
    /// themselves are checked once they are in their buffers
    /// (`checkGeometry`).
    init(decoding data: Data) throws {
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
        let mergedIndexCount = Int(reader.uint32())
        // Reserved. The first bakes of this version stated a zoom here that
        // the models showed from. There is no such rule: a loaded tile draws.
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
              indexCount % 3 == 0, mergedIndexCount % 3 == 0, mergedIndexCount <= indexCount else {
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
            let element: ImmersiveMapOSMElement
            switch entry >> Self.replacedBuildingKindShift {
            case 1: element = .node(id)
            case 2: element = .way(id)
            case 3: element = .relation(id)
            default:
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
            let flags = reader.uint32()
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
                                cutsIntoGround: flags & 1 != 0,
                                replacedBuildings: Array(replacedElements[firstReplaced..<(firstReplaced + replacedCount)]),
                                firstIndex: firstIndex,
                                indexCount: modelIndexCount,
                                boundsMinimum: boundsMinimum,
                                boundsMaximum: boundsMaximum))
        }

        // The merged indices are those of the models that do not cut into
        // the ground, and those models come first: the one call draws them
        // and nothing else.
        let mergedEnd = models.filter { $0.cutsIntoGround == false }.map { $0.firstIndex + $0.indexCount }.max() ?? 0
        let separateStart = models.filter(\.cutsIntoGround).map(\.firstIndex).min() ?? indexCount
        guard mergedEnd <= mergedIndexCount, mergedIndexCount <= separateStart else {
            throw ModelTileFormatError.malformed("the merged index count cuts through a model")
        }

        self.tile = Tile(x: x, y: y, z: zoom)
        self.models = models
        self.vertexCount = vertexCount
        self.indexCount = indexCount
        self.mergedIndexCount = mergedIndexCount
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
    func checkGeometry(vertices: UnsafeRawBufferPointer, indices: UnsafeRawBufferPointer) throws {
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

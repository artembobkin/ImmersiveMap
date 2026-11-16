// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// A model tile to be written: what a baker hands over, and `serialized`
/// lays out as the format describes (`ModelTileContents`, whose comment is
/// the reference). Every model of the tile is merged into one vertex block
/// and one index block, in the tile's own space, with one texture array.
///
/// The baker owns everything before the bytes: reading the models, placing
/// them in tile space, encoding the textures, merging the vertices
/// (`ModelTileVertex`). This type owns the layout alone.
public struct ModelTile {
    public struct Model {
        public var id: String
        /// The model's origin, in degrees, and its height above the map's
        /// surface in meters, already in the vertices.
        public var latitude: Double
        public var longitude: Double
        public var altitudeMeters: Float
        /// The features of the map's own tiles the model stands in for,
        /// each in the map tiles of one zoom.
        public var replacedBuildings: [ModelTileContents.ReplacedBuilding]
        /// The model's part of the tile's index and vertex blocks.
        public var firstIndex: UInt32
        public var indexCount: UInt32
        public var firstVertex: UInt32
        public var vertexCount: UInt32
        /// In tile space.
        public var boundsMinimum: SIMD3<Float>
        public var boundsMaximum: SIMD3<Float>

        public init(id: String,
                    latitude: Double,
                    longitude: Double,
                    altitudeMeters: Float,
                    replacedBuildings: [ModelTileContents.ReplacedBuilding],
                    firstIndex: UInt32,
                    indexCount: UInt32,
                    firstVertex: UInt32,
                    vertexCount: UInt32,
                    boundsMinimum: SIMD3<Float>,
                    boundsMaximum: SIMD3<Float>) {
            self.id = id
            self.latitude = latitude
            self.longitude = longitude
            self.altitudeMeters = altitudeMeters
            self.replacedBuildings = replacedBuildings
            self.firstIndex = firstIndex
            self.indexCount = indexCount
            self.firstVertex = firstVertex
            self.vertexCount = vertexCount
            self.boundsMinimum = boundsMinimum
            self.boundsMaximum = boundsMaximum
        }
    }

    /// The texture array of a tile: `levels[level][layer]` is the ASTC
    /// blocks of one layer at one mip level.
    public struct Texture {
        public var width: Int
        public var height: Int
        /// The edge of an ASTC block in pixels: 8 for 8x8.
        public var blockEdge: Int
        public var layerCount: Int
        public var levels: [[Data]]

        public init(width: Int, height: Int, blockEdge: Int, layerCount: Int, levels: [[Data]]) {
            self.width = width
            self.height = height
            self.blockEdge = blockEdge
            self.layerCount = layerCount
            self.levels = levels
        }
    }

    /// The map tile the models' origins lie in.
    public var zoom: Int
    public var x: Int
    public var y: Int
    /// The models, every one's indices merged.
    public var models: [Model]
    /// The bounds of every vertex of the tile, in tile space: the box the
    /// vertices' positions are places in (`ModelTileVertex.place`).
    public var boundsMinimum: SIMD3<Float>
    public var boundsMaximum: SIMD3<Float>
    /// `vertexCount` vertices of `ModelTileContents.vertexStride` bytes,
    /// each written by `ModelTileVertex.append(to:)`.
    public var vertices: Data
    /// A triangle list, an index counting from the start of `vertices`.
    public var indices: [UInt32]
    public var texture: Texture

    public init(zoom: Int,
                x: Int,
                y: Int,
                models: [Model],
                boundsMinimum: SIMD3<Float>,
                boundsMaximum: SIMD3<Float>,
                vertices: Data,
                indices: [UInt32],
                texture: Texture) {
        self.zoom = zoom
        self.x = x
        self.y = y
        self.models = models
        self.boundsMinimum = boundsMinimum
        self.boundsMaximum = boundsMaximum
        self.vertices = vertices
        self.indices = indices
        self.texture = texture
    }

    public var vertexCount: Int {
        vertices.count / ModelTileContents.vertexStride
    }

    /// The tile's bytes, as `ModelTileContents(decoding:)` reads them.
    public func serialized() -> Data {
        var strings = Data()
        var table = ByteWriter()
        var replaced = ByteWriter()
        for model in models {
            let idBytes = Data(model.id.utf8)
            table.append(model.latitude)
            table.append(model.longitude)
            table.append(model.altitudeMeters)
            table.append(UInt32(replaced.count / ModelTileContents.replacedBuildingEntryByteCount))
            table.append(UInt32(model.replacedBuildings.count))
            for entry in model.replacedBuildings {
                replaced.append(entry.element.entry)
                replaced.append(UInt32(entry.mapTileZoom))
                replaced.append(UInt32(0))
            }
            table.append(UInt32(0))
            table.append(UInt32(strings.count))
            table.append(UInt32(idBytes.count))
            table.append(model.firstIndex)
            table.append(model.indexCount)
            table.append(model.firstVertex)
            table.append(model.vertexCount)
            for value in [model.boundsMinimum.x, model.boundsMinimum.y, model.boundsMinimum.z,
                          model.boundsMaximum.x, model.boundsMaximum.y, model.boundsMaximum.z] {
                table.append(value)
            }
            table.append(UInt32(0))
            strings.append(idBytes)
        }
        precondition(table.count == models.count * ModelTileContents.modelRecordByteCount)

        var indexBlock = ByteWriter()
        for index in indices {
            indexBlock.append(index)
        }
        var textureBlock = Data()
        for level in texture.levels {
            precondition(level.count == texture.layerCount)
            for layer in level {
                textureBlock.append(layer)
            }
        }

        func aligned(_ offset: Int) -> Int {
            let alignment = ModelTileContents.blockAlignment
            return (offset + alignment - 1) / alignment * alignment
        }
        let tableOffset = ModelTileContents.headerByteCount
        let stringsOffset = tableOffset + table.count
        let replacedOffset = stringsOffset + strings.count
        let verticesOffset = aligned(replacedOffset + replaced.count)
        let indicesOffset = aligned(verticesOffset + vertices.count)
        let textureOffset = aligned(indicesOffset + indexBlock.count)

        var writer = ByteWriter()
        writer.append(ModelTileContents.magic)
        writer.append(ModelTileContents.version)
        writer.append(UInt32(zoom))
        writer.append(UInt32(x))
        writer.append(UInt32(y))
        writer.append(UInt32(models.count))
        writer.append(UInt32(vertexCount))
        writer.append(UInt32(indices.count))
        writer.append(UInt32(ModelTileContents.vertexStride))
        writer.append(UInt32(texture.layerCount))
        writer.append(UInt32(texture.width))
        writer.append(UInt32(texture.height))
        writer.append(UInt32(texture.levels.count))
        writer.append(UInt32(texture.blockEdge))
        for (offset, byteCount) in [(tableOffset, table.count),
                                    (stringsOffset, strings.count),
                                    (verticesOffset, vertices.count),
                                    (indicesOffset, indexBlock.count),
                                    (textureOffset, textureBlock.count),
                                    (replacedOffset, replaced.count)] {
            writer.append(UInt32(offset))
            writer.append(UInt32(byteCount))
        }
        // Reserved.
        writer.append(UInt32(0))
        writer.append(UInt32(0))
        for value in [boundsMinimum.x, boundsMinimum.y, boundsMinimum.z,
                      boundsMaximum.x, boundsMaximum.y, boundsMaximum.z] {
            writer.append(value)
        }
        precondition(writer.count == ModelTileContents.headerByteCount)

        writer.append(table.data)
        writer.append(strings)
        writer.append(replaced.data)
        writer.pad(toMultipleOf: ModelTileContents.blockAlignment)
        precondition(writer.count == verticesOffset)
        writer.append(vertices)
        writer.pad(toMultipleOf: ModelTileContents.blockAlignment)
        precondition(writer.count == indicesOffset)
        writer.append(indexBlock.data)
        writer.pad(toMultipleOf: ModelTileContents.blockAlignment)
        precondition(writer.count == textureOffset)
        writer.append(textureBlock)
        writer.pad(toMultipleOf: ModelTileContents.blockAlignment)
        return writer.data
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
@testable import ImmersiveMap
import simd

/// Writes a model tile the way the format describes it, so a test states a
/// tile as models and the bytes travel the engine's decoder. The decoder
/// never sees this code: the fixture has its own writer, as the PMTiles
/// fixtures do, so the round trip checks the decoder against the format and
/// not against itself.
struct ModelTileFixture {
    struct Model {
        var id: String
        var latitude: Double = 55.7558
        var longitude: Double = 37.6173
        var altitudeMeters: Float = 0
        var cutsIntoGround = false
        /// The map features the model replaces: the kind (1 node, 2 way,
        /// 3 relation) and the id of each, and the zoom of the map tiles
        /// the entry is for.
        var replaced: [(kind: UInt64, id: UInt64, zoom: UInt32)] = []
        /// The model's triangles: three vertices each, a position in tile
        /// space and the texture layer.
        var triangles: [[SIMD3<Float>]] = [[SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(0, 20, -5)]]
        var layer: UInt8 = 0
    }

    var zoom = 14
    var x = 9904
    var y = 5121
    /// A model that cuts into the ground goes after the ones that do not,
    /// as the baker orders them.
    var models: [Model] = [Model(id: "model")]
    var layerCount = 1
    var textureSize = 16
    var blockEdge = 8
    /// The alignment of the GPU blocks. The baker uses a page, and a test
    /// keeps its tiles small.
    var blockAlignment = 256

    /// The ASTC block of one opaque colour: a void extent block, the
    /// simplest block the format has.
    static let solidBlock: [UInt8] = [0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                                      0x00, 0x80, 0x00, 0x60, 0x00, 0x40, 0xFF, 0xFF]

    var mipLevelCount: Int {
        Int(log2(Double(textureSize))) + 1
    }

    func serialized() -> Data {
        var strings = Data()
        var replaced = Data()
        var table = Data()
        var vertices = Data()
        var indices = Data()
        var vertexCount: UInt32 = 0
        var indexCount: UInt32 = 0
        var mergedIndexCount: UInt32 = 0
        var tileMinimum = SIMD3<Float>(repeating: .infinity)
        var tileMaximum = SIMD3<Float>(repeating: -.infinity)
        for model in models {
            let firstVertex = vertexCount
            let firstIndex = indexCount
            var minimum = SIMD3<Float>(repeating: .infinity)
            var maximum = SIMD3<Float>(repeating: -.infinity)
            for triangle in model.triangles {
                for position in triangle {
                    minimum = simd_min(minimum, position)
                    maximum = simd_max(maximum, position)
                    append(position.x, to: &vertices)
                    append(position.y, to: &vertices)
                    append(position.z, to: &vertices)
                    // The normal straight up, then the layer.
                    vertices.append(contentsOf: [0, 127, 0, model.layer])
                    append(UInt16(0), to: &vertices)
                    append(UInt16(65_535), to: &vertices)
                    append(vertexCount, to: &indices)
                    vertexCount += 1
                    indexCount += 1
                }
            }
            let id = Data(model.id.utf8)
            append(model.latitude.bitPattern, to: &table)
            append(model.longitude.bitPattern, to: &table)
            append(model.altitudeMeters, to: &table)
            append(UInt32(model.cutsIntoGround ? 1 : 0), to: &table)
            append(UInt32(replaced.count / 16), to: &table)
            append(UInt32(model.replaced.count), to: &table)
            for element in model.replaced {
                append(element.kind << 60 | element.id, to: &replaced)
                append(element.zoom, to: &replaced)
                append(UInt32(0), to: &replaced)
            }
            append(UInt32(0), to: &table)
            if model.cutsIntoGround == false {
                mergedIndexCount = indexCount
            }
            tileMinimum = simd_min(tileMinimum, minimum)
            tileMaximum = simd_max(tileMaximum, maximum)
            append(UInt32(strings.count), to: &table)
            append(UInt32(id.count), to: &table)
            append(firstIndex, to: &table)
            append(indexCount - firstIndex, to: &table)
            append(firstVertex, to: &table)
            append(vertexCount - firstVertex, to: &table)
            for value in [minimum.x, minimum.y, minimum.z, maximum.x, maximum.y, maximum.z] {
                append(value, to: &table)
            }
            append(UInt32(0), to: &table)
            strings.append(id)
        }

        var texture = Data()
        for level in 0..<mipLevelCount {
            let size = max(1, textureSize >> level)
            let blocks = (size + blockEdge - 1) / blockEdge
            for _ in 0..<(layerCount * blocks * blocks) {
                texture.append(contentsOf: Self.solidBlock)
            }
        }

        func aligned(_ offset: Int) -> Int {
            (offset + blockAlignment - 1) / blockAlignment * blockAlignment
        }
        let tableOffset = 136
        let stringsOffset = tableOffset + table.count
        let replacedOffset = stringsOffset + strings.count
        let verticesOffset = aligned(replacedOffset + replaced.count)
        let indicesOffset = aligned(verticesOffset + vertices.count)
        let textureOffset = aligned(indicesOffset + indices.count)

        var tile = Data("IMMT".utf8)
        for value in [4, zoom, x, y, models.count, Int(vertexCount), Int(indexCount), 20,
                      layerCount, textureSize, textureSize, mipLevelCount, blockEdge,
                      tableOffset, table.count, stringsOffset, strings.count,
                      verticesOffset, vertices.count, indicesOffset, indices.count,
                      textureOffset, texture.count,
                      replacedOffset, replaced.count,
                      Int(mergedIndexCount), 0] {
            append(UInt32(value), to: &tile)
        }
        for value in [tileMinimum.x, tileMinimum.y, tileMinimum.z, tileMaximum.x, tileMaximum.y, tileMaximum.z] {
            append(value, to: &tile)
        }
        tile.append(table)
        tile.append(strings)
        tile.append(replaced)
        tile.append(Data(count: verticesOffset - tile.count))
        tile.append(vertices)
        tile.append(Data(count: indicesOffset - tile.count))
        tile.append(indices)
        tile.append(Data(count: textureOffset - tile.count))
        tile.append(texture)
        tile.append(Data(count: aligned(tile.count) - tile.count))
        return tile
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func append(_ value: Float, to data: inout Data) {
        append(value.bitPattern, to: &data)
    }
}

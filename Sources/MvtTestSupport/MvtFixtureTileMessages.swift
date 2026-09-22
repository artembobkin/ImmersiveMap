// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// Synthetic tiles stated as messages: a dense z16 city tile that drives
/// every parse path (water, landcover, landuse, buildings, roads, road names,
/// POIs, places, house numbers) and a z4 ocean overview whose one polygon
/// carries many island holes. The parser benchmark measures them and the
/// decoder tests round-trip them.
package enum MvtFixtureTileMessages {
    package static func denseCity() -> MvtTileMessage {
        var generator = MvtSplitMix64Generator(seed: 0x1AB0_57E5)
        var tile = MvtTileMessage()
        tile.layers.append(makeWaterLayer(generator: &generator))
        tile.layers.append(makeLandcoverLayer(generator: &generator))
        tile.layers.append(makeLanduseLayer(generator: &generator))
        tile.layers.append(makeBuildingLayer(generator: &generator))
        tile.layers.append(makeTransportationLayer(generator: &generator))
        tile.layers.append(makeTransportationNameLayer(generator: &generator))
        tile.layers.append(makePoiLayer(generator: &generator))
        tile.layers.append(makePlaceLayer(generator: &generator))
        tile.layers.append(makeHousenumberLayer(generator: &generator))
        return tile
    }

    package static func oceanOverview() -> MvtTileMessage {
        var generator = MvtSplitMix64Generator(seed: 0x0CEA_0CEA)
        var tile = MvtTileMessage()

        var layer = layerTemplate(name: "water")
        layer.keys = ["class"]
        layer.values = [stringValue("ocean")]

        // One ocean polygon spanning the whole tile with many island holes:
        // drives hole-aware earcut triangulation over a large ring.
        var rings: [[(Int32, Int32)]] = []
        rings.append(jaggedRing(centerX: 2048, centerY: 2048, radius: 2600,
                                vertexCount: 220, generator: &generator))
        for _ in 0..<70 {
            let cx = Int32(generator.int(300...3800))
            let cy = Int32(generator.int(300...3800))
            let radius = Int32(generator.int(30...140))
            rings.append(jaggedRing(centerX: cx, centerY: cy, radius: radius,
                                    vertexCount: generator.int(6...18),
                                    generator: &generator).reversed())
        }
        var feature = MvtFeatureMessage()
        feature.id = 1
        feature.type = .polygon
        feature.geometry = encodePolygonGeometry(rings: rings)
        feature.tags = [0, 0]
        layer.features.append(feature)

        tile.layers = [layer]
        return tile
    }

    private static func makeWaterLayer(generator: inout MvtSplitMix64Generator) -> MvtLayerMessage {
        var layer = layerTemplate(name: "water")
        layer.keys = ["class"]
        layer.values = [stringValue("river"), stringValue("lake")]

        for featureIndex in 0..<6 {
            let cx = Int32(generator.int(200...3800))
            let cy = Int32(generator.int(200...3800))
            var rings: [[(Int32, Int32)]] = []
            rings.append(jaggedRing(centerX: cx, centerY: cy,
                                    radius: Int32(generator.int(180...600)),
                                    vertexCount: generator.int(24...80),
                                    generator: &generator))
            if featureIndex % 2 == 0 {
                rings.append(jaggedRing(centerX: cx, centerY: cy,
                                        radius: Int32(generator.int(40...120)),
                                        vertexCount: generator.int(8...20),
                                        generator: &generator).reversed())
            }
            var feature = MvtFeatureMessage()
            feature.id = UInt64(featureIndex + 1)
            feature.type = .polygon
            feature.geometry = encodePolygonGeometry(rings: rings)
            feature.tags = [0, UInt32(featureIndex % 2)]
            layer.features.append(feature)
        }
        return layer
    }

    private static func makeLandcoverLayer(generator: inout MvtSplitMix64Generator) -> MvtLayerMessage {
        var layer = layerTemplate(name: "landcover")
        layer.keys = ["class", "subclass"]
        layer.values = [stringValue("grass"), stringValue("wood"), stringValue("park")]

        for featureIndex in 0..<40 {
            var feature = MvtFeatureMessage()
            feature.id = UInt64(featureIndex + 1)
            feature.type = .polygon
            feature.geometry = encodePolygonGeometry(rings: [
                jaggedRing(centerX: Int32(generator.int(-200...4300)),
                           centerY: Int32(generator.int(-200...4300)),
                           radius: Int32(generator.int(80...420)),
                           vertexCount: generator.int(12...60),
                           generator: &generator)
            ])
            feature.tags = [0, UInt32(featureIndex % 2), 1, 2]
            layer.features.append(feature)
        }
        return layer
    }

    private static func makeLanduseLayer(generator: inout MvtSplitMix64Generator) -> MvtLayerMessage {
        var layer = layerTemplate(name: "landuse")
        layer.keys = ["class"]
        layer.values = [stringValue("residential"), stringValue("commercial"), stringValue("industrial")]

        for featureIndex in 0..<25 {
            var feature = MvtFeatureMessage()
            feature.id = UInt64(featureIndex + 1)
            feature.type = .polygon
            feature.geometry = encodePolygonGeometry(rings: [
                jaggedRing(centerX: Int32(generator.int(100...4000)),
                           centerY: Int32(generator.int(100...4000)),
                           radius: Int32(generator.int(150...500)),
                           vertexCount: generator.int(8...30),
                           generator: &generator)
            ])
            feature.tags = [0, UInt32(featureIndex % 3)]
            layer.features.append(feature)
        }
        return layer
    }

    private static func makeBuildingLayer(generator: inout MvtSplitMix64Generator) -> MvtLayerMessage {
        var layer = layerTemplate(name: "building")
        layer.keys = ["render_height", "render_min_height", "building:part", "hide_3d", "colour"]
        var values: [MvtValue] = []
        for height in 0..<64 {
            let value = MvtValue.double(Double(4 + height * 3))
            values.append(value)
        }
        let minHeightValue = MvtValue.double(3.0)
        values.append(minHeightValue) // 64
        let truthyValue = MvtValue.bool(true)
        values.append(truthyValue) // 65
        layer.values = values

        for featureIndex in 0..<1500 {
            let originX = Int32(generator.int(0...3950))
            let originY = Int32(generator.int(0...3950))
            let width = Int32(generator.int(24...120))
            let depth = Int32(generator.int(24...120))
            let ring: [(Int32, Int32)]
            if featureIndex % 5 == 0 {
                // L-shaped footprint
                let notchW = max(8, width / 2)
                let notchD = max(8, depth / 2)
                ring = [
                    (originX, originY),
                    (originX + width, originY),
                    (originX + width, originY + notchD),
                    (originX + notchW, originY + notchD),
                    (originX + notchW, originY + depth),
                    (originX, originY + depth)
                ]
            } else {
                ring = [
                    (originX, originY),
                    (originX + width, originY),
                    (originX + width, originY + depth),
                    (originX, originY + depth)
                ]
            }

            var feature = MvtFeatureMessage()
            feature.id = UInt64(featureIndex + 1)
            feature.type = .polygon
            feature.geometry = encodePolygonGeometry(rings: [orientExterior(ring)])
            var tags: [UInt32] = [0, UInt32(featureIndex % 64)]
            if featureIndex % 7 == 0 {
                tags.append(contentsOf: [1, 64])
            }
            if featureIndex % 97 == 0 {
                tags.append(contentsOf: [3, 65])
            }
            feature.tags = tags
            layer.features.append(feature)
        }
        return layer
    }

    private static func makeTransportationLayer(generator: inout MvtSplitMix64Generator) -> MvtLayerMessage {
        var layer = layerTemplate(name: "transportation")
        layer.keys = ["class", "brunnel", "oneway", "layer", "subclass"]
        layer.values = [
            stringValue("motorway"),   // 0
            stringValue("primary"),    // 1
            stringValue("secondary"),  // 2
            stringValue("minor"),      // 3
            stringValue("service"),    // 4
            stringValue("bridge"),     // 5
            stringValue("tunnel"),     // 6
            intValue(1),               // 7
            intValue(-1)               // 8
        ]

        for featureIndex in 0..<500 {
            var feature = MvtFeatureMessage()
            feature.id = UInt64(featureIndex + 1)
            feature.type = .linestring
            feature.geometry = encodeLineGeometry(
                lines: randomPolylines(count: featureIndex % 11 == 0 ? 2 : 1,
                                       pointRange: 4...36,
                                       generator: &generator)
            )

            var tags: [UInt32] = [0, UInt32(featureIndex % 5)]
            if featureIndex % 13 == 0 {
                tags.append(contentsOf: [1, 5]) // bridge
            } else if featureIndex % 17 == 0 {
                tags.append(contentsOf: [1, 6]) // tunnel
                tags.append(contentsOf: [3, 8]) // layer -1
            }
            if featureIndex % 3 == 0 {
                tags.append(contentsOf: [2, 7]) // oneway
            }
            feature.tags = tags
            layer.features.append(feature)
        }
        return layer
    }

    private static func makeTransportationNameLayer(generator: inout MvtSplitMix64Generator) -> MvtLayerMessage {
        var layer = layerTemplate(name: "transportation_name")
        layer.keys = ["class", "name", "name:en", "name:ru", "ref"]
        var values: [MvtValue] = [
            stringValue("primary"),
            stringValue("secondary"),
            stringValue("minor")
        ]
        let streetNames = [
            "Tverskaya Street", "Arbat Street", "Nevsky Avenue", "Sadovaya Street",
            "Leninsky Avenue", "Kutuzovsky Avenue", "Mira Avenue", "Prospekt Vernadskogo"
        ]
        let localNames = [
            "Тверская улица", "Арбат", "Невский проспект", "Садовая улица",
            "Ленинский проспект", "Кутузовский проспект", "Проспект Мира", "Проспект Вернадского"
        ]
        for name in streetNames {
            values.append(stringValue(name))
        }
        for name in localNames {
            values.append(stringValue(name))
        }
        layer.values = values

        for featureIndex in 0..<120 {
            var feature = MvtFeatureMessage()
            feature.id = UInt64(featureIndex + 1)
            feature.type = .linestring
            feature.geometry = encodeLineGeometry(
                lines: randomPolylines(count: 1, pointRange: 6...30, generator: &generator)
            )
            let nameIndex = UInt32(3 + featureIndex % 8)
            feature.tags = [
                0, UInt32(featureIndex % 3),
                1, nameIndex + 8,
                2, nameIndex,
                3, nameIndex + 8
            ]
            layer.features.append(feature)
        }
        return layer
    }

    private static func makePoiLayer(generator: inout MvtSplitMix64Generator) -> MvtLayerMessage {
        var layer = layerTemplate(name: "poi")
        layer.keys = ["class", "subclass", "name", "name:en", "rank"]
        var values: [MvtValue] = [
            stringValue("restaurant"),
            stringValue("cafe"),
            stringValue("shop"),
            stringValue("museum"),
            stringValue("park")
        ]
        for poiIndex in 0..<40 {
            values.append(stringValue("Point of Interest \(poiIndex)"))
        }
        for rank in 0..<10 {
            values.append(intValue(Int64(rank)))
        }
        layer.values = values

        for featureIndex in 0..<150 {
            var feature = MvtFeatureMessage()
            feature.id = UInt64(featureIndex + 1)
            feature.type = .point
            feature.geometry = encodePointGeometry(points: [
                (Int32(generator.int(0...4095)), Int32(generator.int(0...4095)))
            ])
            feature.tags = [
                0, UInt32(featureIndex % 5),
                1, UInt32(featureIndex % 5),
                2, UInt32(5 + featureIndex % 40),
                3, UInt32(5 + featureIndex % 40),
                4, UInt32(45 + featureIndex % 10)
            ]
            layer.features.append(feature)
        }
        return layer
    }

    private static func makePlaceLayer(generator: inout MvtSplitMix64Generator) -> MvtLayerMessage {
        var layer = layerTemplate(name: "place")
        layer.keys = ["class", "name", "name:en", "name:ru", "rank", "capital"]
        var values: [MvtValue] = [
            stringValue("suburb"),
            stringValue("neighbourhood"),
            stringValue("quarter")
        ]
        for placeIndex in 0..<20 {
            values.append(stringValue("District \(placeIndex)"))
        }
        for placeIndex in 0..<20 {
            values.append(stringValue("Район \(placeIndex)"))
        }
        for rank in 0..<8 {
            values.append(intValue(Int64(rank + 1)))
        }
        layer.values = values

        for featureIndex in 0..<40 {
            var feature = MvtFeatureMessage()
            feature.id = UInt64(featureIndex + 1)
            feature.type = .point
            feature.geometry = encodePointGeometry(points: [
                (Int32(generator.int(100...3995)), Int32(generator.int(100...3995)))
            ])
            feature.tags = [
                0, UInt32(featureIndex % 3),
                1, UInt32(3 + 20 + featureIndex % 20),
                2, UInt32(3 + featureIndex % 20),
                3, UInt32(3 + 20 + featureIndex % 20),
                4, UInt32(43 + featureIndex % 8)
            ]
            layer.features.append(feature)
        }
        return layer
    }

    private static func makeHousenumberLayer(generator: inout MvtSplitMix64Generator) -> MvtLayerMessage {
        var layer = layerTemplate(name: "housenumber")
        layer.keys = ["housenumber"]
        var values: [MvtValue] = []
        for number in 0..<100 {
            values.append(stringValue("\(number + 1)"))
        }
        layer.values = values

        for featureIndex in 0..<200 {
            var feature = MvtFeatureMessage()
            feature.id = UInt64(featureIndex + 1)
            feature.type = .point
            feature.geometry = encodePointGeometry(points: [
                (Int32(generator.int(0...4095)), Int32(generator.int(0...4095)))
            ])
            feature.tags = [0, UInt32(featureIndex % 100)]
            layer.features.append(feature)
        }
        return layer
    }

    // MARK: - Geometry helpers

    private static func layerTemplate(name: String) -> MvtLayerMessage {
        var layer = MvtLayerMessage()
        layer.version = 2
        layer.name = name
        layer.extent = 4096
        return layer
    }

    private static func jaggedRing(centerX: Int32,
                                   centerY: Int32,
                                   radius: Int32,
                                   vertexCount: Int,
                                   generator: inout MvtSplitMix64Generator) -> [(Int32, Int32)] {
        var ring: [(Int32, Int32)] = []
        ring.reserveCapacity(vertexCount)
        for vertexIndex in 0..<vertexCount {
            let angle = 2.0 * Double.pi * Double(vertexIndex) / Double(vertexCount)
            let wobble = Double(generator.int(70...130)) / 100.0
            let r = Double(radius) * wobble
            let x = Int32((Double(centerX) + r * cos(angle)).rounded())
            let y = Int32((Double(centerY) + r * sin(angle)).rounded())
            ring.append((x, y))
        }
        return orientExterior(ring)
    }

    /// Ensures positive shoelace sum, the exterior-ring convention the decoder expects.
    private static func orientExterior(_ ring: [(Int32, Int32)]) -> [(Int32, Int32)] {
        var sum: Int64 = 0
        for index in 0..<ring.count {
            let next = (index + 1) % ring.count
            sum += Int64(ring[index].0) * Int64(ring[next].1) - Int64(ring[next].0) * Int64(ring[index].1)
        }
        return sum >= 0 ? ring : ring.reversed()
    }

    private static func randomPolylines(count: Int,
                                        pointRange: ClosedRange<Int>,
                                        generator: inout MvtSplitMix64Generator) -> [[(Int32, Int32)]] {
        var lines: [[(Int32, Int32)]] = []
        for _ in 0..<count {
            var points: [(Int32, Int32)] = []
            var x = Int32(generator.int(-300...4400))
            var y = Int32(generator.int(-300...4400))
            points.append((x, y))
            for _ in 1..<generator.int(pointRange) {
                x += Int32(generator.int(-220...220))
                y += Int32(generator.int(-220...220))
                points.append((x, y))
            }
            lines.append(points)
        }
        return lines
    }

    private static func zigzag(_ value: Int32) -> UInt32 {
        UInt32(bitPattern: (value << 1) ^ (value >> 31))
    }

    private static func command(id: UInt32, count: Int) -> UInt32 {
        (UInt32(count) << 3) | id
    }

    private static func encodePolygonGeometry(rings: [[(Int32, Int32)]]) -> [UInt32] {
        var geometry: [UInt32] = []
        var cursorX: Int32 = 0
        var cursorY: Int32 = 0
        for ring in rings {
            guard ring.count >= 3 else { continue }
            geometry.append(command(id: 1, count: 1))
            geometry.append(zigzag(ring[0].0 - cursorX))
            geometry.append(zigzag(ring[0].1 - cursorY))
            cursorX = ring[0].0
            cursorY = ring[0].1
            geometry.append(command(id: 2, count: ring.count - 1))
            for point in ring.dropFirst() {
                geometry.append(zigzag(point.0 - cursorX))
                geometry.append(zigzag(point.1 - cursorY))
                cursorX = point.0
                cursorY = point.1
            }
            geometry.append(command(id: 7, count: 1))
        }
        return geometry
    }

    private static func encodeLineGeometry(lines: [[(Int32, Int32)]]) -> [UInt32] {
        var geometry: [UInt32] = []
        var cursorX: Int32 = 0
        var cursorY: Int32 = 0
        for line in lines {
            guard line.count >= 2 else { continue }
            geometry.append(command(id: 1, count: 1))
            geometry.append(zigzag(line[0].0 - cursorX))
            geometry.append(zigzag(line[0].1 - cursorY))
            cursorX = line[0].0
            cursorY = line[0].1
            geometry.append(command(id: 2, count: line.count - 1))
            for point in line.dropFirst() {
                geometry.append(zigzag(point.0 - cursorX))
                geometry.append(zigzag(point.1 - cursorY))
                cursorX = point.0
                cursorY = point.1
            }
        }
        return geometry
    }

    private static func encodePointGeometry(points: [(Int32, Int32)]) -> [UInt32] {
        var geometry: [UInt32] = []
        var cursorX: Int32 = 0
        var cursorY: Int32 = 0
        geometry.append(command(id: 1, count: points.count))
        for point in points {
            geometry.append(zigzag(point.0 - cursorX))
            geometry.append(zigzag(point.1 - cursorY))
            cursorX = point.0
            cursorY = point.1
        }
        return geometry
    }

    private static func stringValue(_ value: String) -> MvtValue {
        .string(value)
    }

    private static func intValue(_ value: Int64) -> MvtValue {
        .int(value)
    }
}

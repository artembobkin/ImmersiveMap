// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import MvtTestSupport
import XCTest

/// The hand-written wire decoder is validated two ways: every tile a test
/// states as messages (`MvtTileMessage`) must decode back to those messages
/// field by field, with the packed tag/geometry ranges materialized for
/// comparison; and hand-laid wire bytes exercising the encodings the test
/// encoder never writes (unpacked repeated fields, split packed runs,
/// unknown fields, groups, duplicate scalars) must decode to the messages
/// the protobuf encoding rules assign them.
final class MvtTileDecoderTests: XCTestCase {
    // MARK: - Round trips

    func testRoundTripsDenseCityTile() throws {
        try assertRoundTrips(MvtFixtureTileMessages.denseCity())
    }

    func testRoundTripsOceanOverviewTile() throws {
        try assertRoundTrips(MvtFixtureTileMessages.oceanOverview())
    }

    func testRoundTripsRandomizedTiles() throws {
        var generator = MvtSplitMix64Generator(seed: 0xDEC0DE)

        for round in 0..<100 {
            var tile = MvtTileMessage()
            let layerCount = Int(generator.next() % 4)
            for layerNumber in 0..<layerCount {
                var layer = MvtLayerMessage()
                layer.version = 2
                layer.name = "layer_\(round)_\(layerNumber)"
                if generator.next() % 3 == 0 {
                    layer.extent = UInt32(1 + generator.next() % 8192)
                }

                let keyCount = Int(generator.next() % 6)
                for keyNumber in 0..<keyCount {
                    layer.keys.append("key_\(keyNumber)")
                    layer.values.append(randomValue(&generator))
                }

                let featureCount = Int(generator.next() % 8)
                for _ in 0..<featureCount {
                    var feature = MvtFeatureMessage()
                    if generator.next() % 2 == 0 {
                        feature.id = generator.next()
                    }
                    if let geomType = MvtGeometryType(rawValue: Int(generator.next() % 4)) {
                        feature.type = geomType
                    }
                    let tagCount = Int(generator.next() % 6) * 2
                    for _ in 0..<tagCount {
                        feature.tags.append(UInt32(generator.next() % 8))
                    }
                    let geometryCount = Int(generator.next() % 40)
                    for _ in 0..<geometryCount {
                        feature.geometry.append(UInt32(truncatingIfNeeded: generator.next()))
                    }
                    layer.features.append(feature)
                }

                tile.layers.append(layer)
            }

            try assertRoundTrips(tile, context: "round \(round)")
        }
    }

    func testValueMessageFieldKinds() throws {
        var layer = MvtLayerMessage()
        layer.version = 2
        layer.name = "values"
        layer.keys = ["s", "f", "d", "i", "u", "si", "b"]
        layer.values = [
            .string("Тверская улица"),
            .float(3.5),
            .double(-128.0625),
            .int(-42),
            .uint(UInt64.max),
            .sint(-123456789),
            .bool(true)
        ]

        try assertRoundTrips(MvtTileMessage(layers: [layer]))
    }

    func testEmptyValueMessageDecodesAsAbsent() throws {
        var layer = MvtLayerMessage()
        layer.name = "values"
        layer.keys = ["nothing"]
        layer.values = [.absent]

        try assertRoundTrips(MvtTileMessage(layers: [layer]))
    }

    // MARK: - Wire-format edge cases

    func testUnpackedRepeatedFieldsDecodeLikePacked() throws {
        // Feature with tags and geometry encoded element-by-element (wire
        // type 0 per value) instead of one packed LEN run.
        var featureBody = MvtWireWriter()
        featureBody.appendVarint(fieldNumber: 1, value: 42)
        for tag in [0, 1, 2, 3] {
            featureBody.appendVarint(fieldNumber: 2, value: UInt64(tag))
        }
        featureBody.appendVarint(fieldNumber: 3, value: 1) // point
        for value in [9, 50, 34] {
            featureBody.appendVarint(fieldNumber: 4, value: UInt64(value))
        }

        let data = wrapFeatureInTile(featureBody: featureBody.data,
                                     keys: ["a", "b"],
                                     values: ["va", "vb"])
        try assertDecodes(data, as: edgeTile(keys: ["a", "b"],
                                             values: ["va", "vb"],
                                             feature: MvtFeatureMessage(id: 42,
                                                                        tags: [0, 1, 2, 3],
                                                                        type: .point,
                                                                        geometry: [9, 50, 34])))
    }

    func testSplitPackedRunsConcatenate() throws {
        // The same packed field appearing twice must decode as one
        // concatenated sequence.
        var featureBody = MvtWireWriter()
        featureBody.appendPackedVarints(fieldNumber: 4, values: [9, 50])
        featureBody.appendPackedVarints(fieldNumber: 4, values: [34])
        featureBody.appendVarint(fieldNumber: 3, value: 1)

        let data = wrapFeatureInTile(featureBody: featureBody.data, keys: [], values: [])
        try assertDecodes(data, as: edgeTile(feature: MvtFeatureMessage(type: .point, geometry: [9, 50, 34])))
    }

    func testUnknownFieldsAreSkipped() throws {
        var featureBody = MvtWireWriter()
        featureBody.appendVarint(fieldNumber: 1, value: 7)
        // Unknown varint, fixed32, fixed64 and length-delimited fields.
        featureBody.appendVarint(fieldNumber: 9, value: 123456789)
        featureBody.appendFixed32(fieldNumber: 10, value: 0xAABBCCDD)
        featureBody.appendFixed64(fieldNumber: 11, value: 0x1122334455667788)
        featureBody.appendLengthDelimited(fieldNumber: 12, payload: Data([1, 2, 3, 4, 5]))
        featureBody.appendPackedVarints(fieldNumber: 4, values: [9, 4, 4])

        let data = wrapFeatureInTile(featureBody: featureBody.data, keys: [], values: [])
        try assertDecodes(data, as: edgeTile(feature: MvtFeatureMessage(id: 7, geometry: [9, 4, 4])))
    }

    func testUnknownGroupFieldIsSkipped() throws {
        var featureBody = MvtWireWriter()
        featureBody.appendVarint(fieldNumber: 1, value: 5)
        // A legacy group: SGROUP(14) { varint(1)=9; SGROUP(15) EGROUP(15) }
        // EGROUP(14), a nested group inside the skipped one.
        featureBody.appendTag(fieldNumber: 14, wireType: 3)
        featureBody.appendVarint(fieldNumber: 1, value: 9)
        featureBody.appendTag(fieldNumber: 15, wireType: 3)
        featureBody.appendTag(fieldNumber: 15, wireType: 4)
        featureBody.appendTag(fieldNumber: 14, wireType: 4)
        featureBody.appendPackedVarints(fieldNumber: 4, values: [9, 2, 2])

        let data = wrapFeatureInTile(featureBody: featureBody.data, keys: [], values: [])
        try assertDecodes(data, as: edgeTile(feature: MvtFeatureMessage(id: 5, geometry: [9, 2, 2])))
    }

    func testDuplicateScalarFieldsLastOneWins() throws {
        var layerBody = MvtWireWriter()
        layerBody.appendVarint(fieldNumber: 15, value: 2)
        layerBody.appendLengthDelimited(fieldNumber: 1, payload: Data("first".utf8))
        layerBody.appendLengthDelimited(fieldNumber: 1, payload: Data("second".utf8))
        layerBody.appendVarint(fieldNumber: 5, value: 512)
        layerBody.appendVarint(fieldNumber: 5, value: 2048)

        var tileBody = MvtWireWriter()
        tileBody.appendLengthDelimited(fieldNumber: 3, payload: layerBody.data)

        try assertDecodes(tileBody.data, as: MvtTileMessage(layers: [MvtLayerMessage(name: "second", extent: 2048)]))
    }

    func testDuplicateValueFieldsKeepTheLastOne() throws {
        // The specification allows one field per Value; a message that sets
        // two keeps the later one in wire order.
        var valueBody = MvtWireWriter()
        valueBody.appendVarint(fieldNumber: 5, value: 12)
        valueBody.appendLengthDelimited(fieldNumber: 1, payload: Data("twelve".utf8))

        var layerBody = MvtWireWriter()
        layerBody.appendVarint(fieldNumber: 15, value: 2)
        layerBody.appendLengthDelimited(fieldNumber: 1, payload: Data("values".utf8))
        layerBody.appendLengthDelimited(fieldNumber: 3, payload: Data("k".utf8))
        layerBody.appendLengthDelimited(fieldNumber: 4, payload: valueBody.data)

        var tileBody = MvtWireWriter()
        tileBody.appendLengthDelimited(fieldNumber: 3, payload: layerBody.data)

        try assertDecodes(tileBody.data, as: MvtTileMessage(layers: [
            MvtLayerMessage(name: "values", keys: ["k"], values: [.string("twelve")])
        ]))
    }

    func testMissingRequiredLayerFieldsThrow() {
        // A layer with a name but no version violates the schema's required
        // fields; the decoder rejects the tile.
        var layerBody = MvtWireWriter()
        layerBody.appendLengthDelimited(fieldNumber: 1, payload: Data("no-version".utf8))

        var tileBody = MvtWireWriter()
        tileBody.appendLengthDelimited(fieldNumber: 3, payload: layerBody.data)

        XCTAssertThrowsError(try MvtTileDecoder.decode(data: tileBody.data))
    }

    func testTruncatedInputThrows() throws {
        let data = MvtFixtureTileMessages.denseCity().serializedData()
        let truncated = data.prefix(data.count / 2)
        XCTAssertThrowsError(try MvtTileDecoder.decode(data: Data(truncated)))
    }

    func testMalformedVarintThrows() {
        // Eleven continuation bytes: longer than any valid varint.
        let data = Data(repeating: 0x80, count: 11)
        XCTAssertThrowsError(try MvtTileDecoder.decode(data: data))
    }

    func testEmptyDataDecodesToEmptyTile() throws {
        let decoded = try MvtTileDecoder.decode(data: Data())
        XCTAssertTrue(decoded.layers.isEmpty)
    }

    func testInvalidGeometryTypeLeavesPreviousValue() throws {
        var featureBody = MvtWireWriter()
        featureBody.appendVarint(fieldNumber: 3, value: 2) // linestring
        featureBody.appendVarint(fieldNumber: 3, value: 9) // invalid

        let data = wrapFeatureInTile(featureBody: featureBody.data, keys: [], values: [])
        let decoded = try MvtTileDecoder.decode(data: data)
        XCTAssertEqual(decoded.layers[0].features[0].type, .linestring)
    }

    // MARK: - Geometry reader equivalence

    func testRangeAndArrayGeometryReadersAgree() throws {
        var generator = MvtSplitMix64Generator(seed: 0x6E0)

        for _ in 0..<50 {
            var geometry: [UInt32] = []
            let ringCount = 1 + Int(generator.next() % 3)
            var cursor = (x: Int32(0), y: Int32(0))
            for _ in 0..<ringCount {
                geometry.append((1 << 3) | 1) // MoveTo count 1
                appendZigZagDelta(&geometry, &cursor, &generator)
                let pointCount = 2 + Int(generator.next() % 20)
                geometry.append(UInt32((pointCount << 3) | 2)) // LineTo
                for _ in 0..<pointCount {
                    appendZigZagDelta(&geometry, &cursor, &generator)
                }
                geometry.append((1 << 3) | 7) // ClosePath
            }

            let feature = MvtFeatureMessage(type: .polygon, geometry: geometry)
            let layer = MvtLayerMessage(name: "geometry", features: [feature])
            let data = MvtTileMessage(layers: [layer]).serializedData()
            let decoded = try MvtTileDecoder.decode(data: data)
            let decodedFeature = decoded.layers[0].features[0]

            guard case .range = decodedFeature.geometry else {
                XCTFail("contiguous packed geometry should decode as a byte range")
                return
            }

            let fromRange = MvtGeometryDecoder.decodePolygons(decodedFeature.geometry, in: data)
            let fromArray = MvtGeometryDecoder.decodePolygons(.values(geometry), in: Data())
            assertPolygonsEqual(fromRange, fromArray)
            XCTAssertEqual(decodedFeature.geometry.materializedValues(data: data), geometry)
        }
    }

    func testGeometryDecodersRejectMalformedStreams() {
        let empty = Data()
        // LineTo before MoveTo.
        XCTAssertTrue(MvtGeometryDecoder.decodePolygons(.values([(1 << 3) | 2, 2, 2]), in: empty).isEmpty)
        // Interior ring (negative shoelace) before any exterior.
        let interiorFirst: [UInt32] = [
            (1 << 3) | 1, zigzag(0), zigzag(0),
            (2 << 3) | 2, zigzag(0), zigzag(10), zigzag(10), zigzag(0),
            (1 << 3) | 7
        ]
        XCTAssertTrue(MvtGeometryDecoder.decodePolygons(.values(interiorFirst), in: empty).isEmpty)
        // Truncated LineTo run.
        XCTAssertTrue(MvtGeometryDecoder.decodeLines(.values([(1 << 3) | 1, 2, 2, (3 << 3) | 2, 2]), in: empty).isEmpty)
    }

    // MARK: - Comparison helpers

    private func assertRoundTrips(_ tile: MvtTileMessage,
                                  context: String = "",
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        try assertDecodes(tile.serializedData(), as: tile, context: context, file: file, line: line)
    }

    /// Decodes `data` and compares the result with `expected` field by field,
    /// reading the schema defaults for the fields the message leaves unset.
    private func assertDecodes(_ data: Data,
                               as expected: MvtTileMessage,
                               context: String = "",
                               file: StaticString = #filePath,
                               line: UInt = #line) throws {
        let decoded = try MvtTileDecoder.decode(data: data)

        // Count mismatches record a failure and return early so the detailed
        // loops below never index out of bounds.
        XCTAssertEqual(decoded.layers.count, expected.layers.count, "layer count \(context)", file: file, line: line)
        guard decoded.layers.count == expected.layers.count else { return }
        for (layerIndex, expectedLayer) in expected.layers.enumerated() {
            let decodedLayer = decoded.layers[layerIndex]
            XCTAssertEqual(decodedLayer.name, expectedLayer.name, "layer name \(context)", file: file, line: line)
            XCTAssertEqual(decodedLayer.extent, expectedLayer.extent ?? 4096, "extent \(context)", file: file, line: line)
            XCTAssertEqual(decodedLayer.keys, expectedLayer.keys, "keys \(context)", file: file, line: line)
            XCTAssertEqual(decodedLayer.values, expectedLayer.values, "values \(context)", file: file, line: line)

            XCTAssertEqual(decodedLayer.features.count, expectedLayer.features.count,
                           "feature count \(context)", file: file, line: line)
            guard decodedLayer.features.count == expectedLayer.features.count else { return }
            for (featureIndex, expectedFeature) in expectedLayer.features.enumerated() {
                let decodedFeature = decodedLayer.features[featureIndex]
                XCTAssertEqual(decodedFeature.hasID, expectedFeature.id != nil,
                               "hasID \(context)", file: file, line: line)
                XCTAssertEqual(decodedFeature.id, expectedFeature.id ?? 0,
                               "id \(context)", file: file, line: line)
                XCTAssertEqual(decodedFeature.type, expectedFeature.type ?? .unknown,
                               "type \(context)", file: file, line: line)
                XCTAssertEqual(decodedFeature.tags.materializedValues(data: data), expectedFeature.tags,
                               "tags \(context)", file: file, line: line)
                XCTAssertEqual(decodedFeature.geometry.materializedValues(data: data), expectedFeature.geometry,
                               "geometry \(context)", file: file, line: line)
            }
        }
    }

    private func assertPolygonsEqual(_ lhs: MultiPolygon,
                                     _ rhs: MultiPolygon,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        for (index, leftPolygon) in lhs.enumerated() {
            let rightPolygon = rhs[index]
            XCTAssertEqual(leftPolygon.exteriorRing.map(\.x), rightPolygon.exteriorRing.map(\.x), file: file, line: line)
            XCTAssertEqual(leftPolygon.exteriorRing.map(\.y), rightPolygon.exteriorRing.map(\.y), file: file, line: line)
            XCTAssertEqual(leftPolygon.interiorRings.count, rightPolygon.interiorRings.count, file: file, line: line)
            for (ringIndex, leftRing) in leftPolygon.interiorRings.enumerated() {
                XCTAssertEqual(leftRing.map(\.x), rightPolygon.interiorRings[ringIndex].map(\.x), file: file, line: line)
                XCTAssertEqual(leftRing.map(\.y), rightPolygon.interiorRings[ringIndex].map(\.y), file: file, line: line)
            }
        }
    }

    // MARK: - Wire fixtures

    /// The tile `wrapFeatureInTile` lays out, as the message it must decode
    /// to: one layer named "edge" with string values and the given feature.
    private func edgeTile(keys: [String] = [], values: [String] = [], feature: MvtFeatureMessage) -> MvtTileMessage {
        MvtTileMessage(layers: [
            MvtLayerMessage(name: "edge", features: [feature], keys: keys, values: values.map(MvtValue.string))
        ])
    }

    private func wrapFeatureInTile(featureBody: Data, keys: [String], values: [String]) -> Data {
        var layerBody = MvtWireWriter()
        layerBody.appendVarint(fieldNumber: 15, value: 2)
        layerBody.appendLengthDelimited(fieldNumber: 1, payload: Data("edge".utf8))
        layerBody.appendLengthDelimited(fieldNumber: 2, payload: featureBody)
        for key in keys {
            layerBody.appendLengthDelimited(fieldNumber: 3, payload: Data(key.utf8))
        }
        for value in values {
            var valueBody = MvtWireWriter()
            valueBody.appendLengthDelimited(fieldNumber: 1, payload: Data(value.utf8))
            layerBody.appendLengthDelimited(fieldNumber: 4, payload: valueBody.data)
        }

        var tileBody = MvtWireWriter()
        tileBody.appendLengthDelimited(fieldNumber: 3, payload: layerBody.data)
        return tileBody.data
    }

    private func randomValue(_ generator: inout MvtSplitMix64Generator) -> MvtValue {
        switch generator.next() % 7 {
        case 0: return .string("value_\(generator.next() % 1000)")
        case 1: return .float(Float(generator.next() % 100_000) / 8.0)
        case 2: return .double(Double(generator.next() % 1_000_000) / 16.0)
        case 3: return .int(Int64(bitPattern: generator.next()))
        case 4: return .uint(generator.next())
        case 5: return .sint(Int64(bitPattern: generator.next()))
        default: return .bool(generator.next() % 2 == 0)
        }
    }

    private func appendZigZagDelta(_ geometry: inout [UInt32],
                                   _ cursor: inout (x: Int32, y: Int32),
                                   _ generator: inout MvtSplitMix64Generator) {
        let dx = Int32(generator.next() % 512) - 256
        let dy = Int32(generator.next() % 512) - 256
        cursor.x &+= dx
        cursor.y &+= dy
        geometry.append(zigzag(dx))
        geometry.append(zigzag(dy))
    }

    private func zigzag(_ value: Int32) -> UInt32 {
        UInt32(bitPattern: (value << 1) ^ (value >> 31))
    }

    /// `integerValue` reads a whole number from whichever field the writer
    /// chose. Planetiler writes `sint` for every integer, so a reader that
    /// knew only `int` read a tunnel's `layer=-1` as absent.
    func testIntegerValueReadsEveryNumericField() {
        XCTAssertEqual(MvtValue.sint(-1).integerValue, -1)
        XCTAssertEqual(MvtValue.sint(51_050_554).integerValue, 51_050_554)
        XCTAssertEqual(MvtValue.int(-3).integerValue, -3)
        XCTAssertEqual(MvtValue.uint(7).integerValue, 7)
        XCTAssertNil(MvtValue.uint(UInt64.max).integerValue)
        XCTAssertEqual(MvtValue.double(2.0).integerValue, 2)
        XCTAssertEqual(MvtValue.string("-1").integerValue, -1)
        XCTAssertNil(MvtValue.string("tunnel").integerValue)
        XCTAssertNil(MvtValue.bool(true).integerValue)
        XCTAssertNil(MvtValue.absent.integerValue)
    }
}

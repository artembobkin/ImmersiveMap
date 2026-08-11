// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The hand-written wire decoder is validated against swift-protobuf as
/// ground truth: every tile a test encodes decodes identically through both,
/// field by field, with the packed tag/geometry ranges materialized for
/// comparison.
final class MvtTileDecoderTests: XCTestCase {
    // MARK: - Equivalence against swift-protobuf

    func testMatchesProtobufOnDenseCityTile() throws {
        try assertDecodesLikeProtobuf(TileMvtParserPerformanceTests.makeDenseCityTile())
    }

    func testMatchesProtobufOnOceanOverviewTile() throws {
        try assertDecodesLikeProtobuf(TileMvtParserPerformanceTests.makeOceanOverviewTile())
    }

    func testMatchesProtobufOnRandomizedTiles() throws {
        var generator = SplitMix64(seed: 0xDEC0DE)

        for round in 0..<100 {
            var tile = VectorTile_Tile()
            let layerCount = Int(generator.next() % 4)
            for layerNumber in 0..<layerCount {
                var layer = VectorTile_Tile.Layer()
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
                for featureNumber in 0..<featureCount {
                    var feature = VectorTile_Tile.Feature()
                    if generator.next() % 2 == 0 {
                        feature.id = generator.next()
                    }
                    if let geomType = VectorTile_Tile.GeomType(rawValue: Int(generator.next() % 4)) {
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
                    _ = featureNumber
                    layer.features.append(feature)
                }

                tile.layers.append(layer)
            }

            try assertDecodesLikeProtobuf(tile, context: "round \(round)")
        }
    }

    // MARK: - Wire-format edge cases

    func testUnpackedRepeatedFieldsDecodeLikePacked() throws {
        // Feature with tags and geometry encoded element-by-element (wire
        // type 0 per value) instead of one packed LEN run.
        var featureBody = Data()
        appendVarintField(&featureBody, fieldNumber: 1, value: 42)
        for tag in [0, 1, 2, 3] {
            appendVarintField(&featureBody, fieldNumber: 2, value: UInt64(tag))
        }
        appendVarintField(&featureBody, fieldNumber: 3, value: 1) // point
        for value in [9, 50, 34] {
            appendVarintField(&featureBody, fieldNumber: 4, value: UInt64(value))
        }

        let data = wrapFeatureInTile(featureBody: featureBody,
                                     keys: ["a", "b"],
                                     values: ["va", "vb"])
        try assertRawBytesDecodeLikeProtobuf(data)
    }

    func testSplitPackedRunsConcatenate() throws {
        // The same packed field appearing twice must decode as one
        // concatenated sequence.
        var featureBody = Data()
        appendPackedVarintField(&featureBody, fieldNumber: 4, values: [9, 50])
        appendPackedVarintField(&featureBody, fieldNumber: 4, values: [34])
        appendVarintField(&featureBody, fieldNumber: 3, value: 1)

        let data = wrapFeatureInTile(featureBody: featureBody, keys: [], values: [])
        try assertRawBytesDecodeLikeProtobuf(data)
    }

    func testUnknownFieldsAreSkipped() throws {
        var featureBody = Data()
        appendVarintField(&featureBody, fieldNumber: 1, value: 7)
        // Unknown varint, fixed32, fixed64 and length-delimited fields.
        appendVarintField(&featureBody, fieldNumber: 9, value: 123456789)
        appendFixed32Field(&featureBody, fieldNumber: 10, value: 0xAABBCCDD)
        appendFixed64Field(&featureBody, fieldNumber: 11, value: 0x1122334455667788)
        appendLengthDelimitedField(&featureBody, fieldNumber: 12, payload: Data([1, 2, 3, 4, 5]))
        appendPackedVarintField(&featureBody, fieldNumber: 4, values: [9, 4, 4])

        let data = wrapFeatureInTile(featureBody: featureBody, keys: [], values: [])
        try assertRawBytesDecodeLikeProtobuf(data)
    }

    func testUnknownGroupFieldIsSkipped() throws {
        var featureBody = Data()
        appendVarintField(&featureBody, fieldNumber: 1, value: 5)
        // A legacy group: SGROUP(14) { varint(1)=9; EGROUP(14) } wrapped
        // around a nested group as well.
        appendVarint(&featureBody, (14 << 3) | 3)
        appendVarintField(&featureBody, fieldNumber: 1, value: 9)
        appendVarint(&featureBody, (15 << 3) | 3)
        appendVarint(&featureBody, (15 << 3) | 4)
        appendVarint(&featureBody, (14 << 3) | 4)
        appendPackedVarintField(&featureBody, fieldNumber: 4, values: [9, 2, 2])

        let data = wrapFeatureInTile(featureBody: featureBody, keys: [], values: [])
        try assertRawBytesDecodeLikeProtobuf(data)
    }

    func testValueMessageFieldKinds() throws {
        var tile = VectorTile_Tile()
        var layer = VectorTile_Tile.Layer()
        layer.version = 2
        layer.name = "values"
        layer.keys = ["s", "f", "d", "i", "u", "si", "b"]

        var stringValue = VectorTile_Tile.Value()
        stringValue.stringValue = "Тверская улица"
        var floatValue = VectorTile_Tile.Value()
        floatValue.floatValue = 3.5
        var doubleValue = VectorTile_Tile.Value()
        doubleValue.doubleValue = -128.0625
        var intValue = VectorTile_Tile.Value()
        intValue.intValue = -42
        var uintValue = VectorTile_Tile.Value()
        uintValue.uintValue = UInt64.max
        var sintValue = VectorTile_Tile.Value()
        sintValue.sintValue = -123456789
        var boolValue = VectorTile_Tile.Value()
        boolValue.boolValue = true

        layer.values = [stringValue, floatValue, doubleValue, intValue, uintValue, sintValue, boolValue]
        tile.layers = [layer]

        try assertDecodesLikeProtobuf(tile)
    }

    func testDuplicateScalarFieldsLastOneWins() throws {
        var layerBody = Data()
        appendVarintField(&layerBody, fieldNumber: 15, value: 2)
        appendLengthDelimitedField(&layerBody, fieldNumber: 1, payload: Data("first".utf8))
        appendLengthDelimitedField(&layerBody, fieldNumber: 1, payload: Data("second".utf8))
        appendVarintField(&layerBody, fieldNumber: 5, value: 512)
        appendVarintField(&layerBody, fieldNumber: 5, value: 2048)

        var tileBody = Data()
        appendLengthDelimitedField(&tileBody, fieldNumber: 3, payload: layerBody)

        let decoded = try MvtTileDecoder.decode(data: tileBody)
        XCTAssertEqual(decoded.layers.count, 1)
        XCTAssertEqual(decoded.layers[0].name, "second")
        XCTAssertEqual(decoded.layers[0].extent, 2048)
        try assertRawBytesDecodeLikeProtobuf(tileBody)
    }

    func testMissingRequiredLayerFieldsThrowLikeProtobuf() {
        // A layer with a name but no version violates the proto2 required
        // fields; both decoders must reject the tile.
        var layerBody = Data()
        appendLengthDelimitedField(&layerBody, fieldNumber: 1, payload: Data("no-version".utf8))

        var tileBody = Data()
        appendLengthDelimitedField(&tileBody, fieldNumber: 3, payload: layerBody)

        XCTAssertThrowsError(try MvtTileDecoder.decode(data: tileBody))
        XCTAssertThrowsError(try VectorTile_Tile(serializedBytes: tileBody))
    }

    func testTruncatedInputThrows() throws {
        let data = try TileMvtParserPerformanceTests.makeDenseCityTile().serializedData()
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
        var featureBody = Data()
        appendVarintField(&featureBody, fieldNumber: 3, value: 2) // linestring
        appendVarintField(&featureBody, fieldNumber: 3, value: 9) // invalid

        let data = wrapFeatureInTile(featureBody: featureBody, keys: [], values: [])
        let decoded = try MvtTileDecoder.decode(data: data)
        XCTAssertEqual(decoded.layers[0].features[0].type, .linestring)

        let reference = try VectorTile_Tile(serializedBytes: data)
        XCTAssertEqual(reference.layers[0].features[0].type, .linestring)
    }

    // MARK: - Geometry reader equivalence

    func testRangeAndArrayGeometryReadersAgree() throws {
        var generator = SplitMix64(seed: 0x6E0)

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

            var feature = VectorTile_Tile.Feature()
            feature.type = .polygon
            feature.geometry = geometry
            var layer = VectorTile_Tile.Layer()
            layer.version = 2
            layer.name = "geometry"
            layer.features = [feature]
            var tile = VectorTile_Tile()
            tile.layers = [layer]

            let data = try tile.serializedData()
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

    private func assertDecodesLikeProtobuf(_ tile: VectorTile_Tile,
                                           context: String = "",
                                           file: StaticString = #filePath,
                                           line: UInt = #line) throws {
        let data = try tile.serializedData()
        try assertRawBytesDecodeLikeProtobuf(data, context: context, file: file, line: line)
    }

    private func assertRawBytesDecodeLikeProtobuf(_ data: Data,
                                                  context: String = "",
                                                  file: StaticString = #filePath,
                                                  line: UInt = #line) throws {
        let reference = try VectorTile_Tile(serializedBytes: data)
        let decoded = try MvtTileDecoder.decode(data: data)

        XCTAssertEqual(decoded.layers.count, reference.layers.count, "layer count \(context)", file: file, line: line)
        for (layerIndex, referenceLayer) in reference.layers.enumerated() {
            let decodedLayer = decoded.layers[layerIndex]
            XCTAssertEqual(decodedLayer.name, referenceLayer.name, "layer name \(context)", file: file, line: line)
            XCTAssertEqual(decodedLayer.extent, referenceLayer.extent, "extent \(context)", file: file, line: line)
            XCTAssertEqual(decodedLayer.keys, referenceLayer.keys, "keys \(context)", file: file, line: line)
            XCTAssertEqual(decodedLayer.values.count, referenceLayer.values.count, "value count \(context)", file: file, line: line)
            for (valueIndex, referenceValue) in referenceLayer.values.enumerated() {
                assertValuesEqual(decodedLayer.values[valueIndex], referenceValue,
                                  context: "\(context) layer \(layerIndex) value \(valueIndex)",
                                  file: file, line: line)
            }

            XCTAssertEqual(decodedLayer.features.count, referenceLayer.features.count,
                           "feature count \(context)", file: file, line: line)
            for (featureIndex, referenceFeature) in referenceLayer.features.enumerated() {
                let decodedFeature = decodedLayer.features[featureIndex]
                XCTAssertEqual(decodedFeature.hasID, referenceFeature.hasID,
                               "hasID \(context)", file: file, line: line)
                XCTAssertEqual(decodedFeature.id, referenceFeature.id,
                               "id \(context)", file: file, line: line)
                XCTAssertEqual(decodedFeature.type, referenceFeature.type,
                               "type \(context)", file: file, line: line)
                XCTAssertEqual(decodedFeature.tags.materializedValues(data: data), referenceFeature.tags,
                               "tags \(context)", file: file, line: line)
                XCTAssertEqual(decodedFeature.geometry.materializedValues(data: data), referenceFeature.geometry,
                               "geometry \(context)", file: file, line: line)
            }
        }
    }

    private func assertValuesEqual(_ decoded: VectorTile_Tile.Value,
                                   _ reference: VectorTile_Tile.Value,
                                   context: String,
                                   file: StaticString,
                                   line: UInt) {
        XCTAssertEqual(decoded.hasStringValue, reference.hasStringValue, context, file: file, line: line)
        XCTAssertEqual(decoded.stringValue, reference.stringValue, context, file: file, line: line)
        XCTAssertEqual(decoded.hasFloatValue, reference.hasFloatValue, context, file: file, line: line)
        XCTAssertEqual(decoded.floatValue, reference.floatValue, context, file: file, line: line)
        XCTAssertEqual(decoded.hasDoubleValue, reference.hasDoubleValue, context, file: file, line: line)
        XCTAssertEqual(decoded.doubleValue, reference.doubleValue, context, file: file, line: line)
        XCTAssertEqual(decoded.hasIntValue, reference.hasIntValue, context, file: file, line: line)
        XCTAssertEqual(decoded.intValue, reference.intValue, context, file: file, line: line)
        XCTAssertEqual(decoded.hasUintValue, reference.hasUintValue, context, file: file, line: line)
        XCTAssertEqual(decoded.uintValue, reference.uintValue, context, file: file, line: line)
        XCTAssertEqual(decoded.hasSintValue, reference.hasSintValue, context, file: file, line: line)
        XCTAssertEqual(decoded.sintValue, reference.sintValue, context, file: file, line: line)
        XCTAssertEqual(decoded.hasBoolValue, reference.hasBoolValue, context, file: file, line: line)
        XCTAssertEqual(decoded.boolValue, reference.boolValue, context, file: file, line: line)
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

    // MARK: - Wire encoding helpers

    private func appendVarint(_ data: inout Data, _ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    private func appendVarintField(_ data: inout Data, fieldNumber: UInt64, value: UInt64) {
        appendVarint(&data, (fieldNumber << 3) | 0)
        appendVarint(&data, value)
    }

    private func appendFixed32Field(_ data: inout Data, fieldNumber: UInt64, value: UInt32) {
        appendVarint(&data, (fieldNumber << 3) | 5)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendFixed64Field(_ data: inout Data, fieldNumber: UInt64, value: UInt64) {
        appendVarint(&data, (fieldNumber << 3) | 1)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendLengthDelimitedField(_ data: inout Data, fieldNumber: UInt64, payload: Data) {
        appendVarint(&data, (fieldNumber << 3) | 2)
        appendVarint(&data, UInt64(payload.count))
        data.append(payload)
    }

    private func appendPackedVarintField(_ data: inout Data, fieldNumber: UInt64, values: [UInt64]) {
        var payload = Data()
        for value in values {
            appendVarint(&payload, value)
        }
        appendLengthDelimitedField(&data, fieldNumber: fieldNumber, payload: payload)
    }

    private func wrapFeatureInTile(featureBody: Data, keys: [String], values: [String]) -> Data {
        var layerBody = Data()
        appendVarintField(&layerBody, fieldNumber: 15, value: 2)
        appendLengthDelimitedField(&layerBody, fieldNumber: 1, payload: Data("edge".utf8))
        appendLengthDelimitedField(&layerBody, fieldNumber: 2, payload: featureBody)
        for key in keys {
            appendLengthDelimitedField(&layerBody, fieldNumber: 3, payload: Data(key.utf8))
        }
        for value in values {
            var valueBody = Data()
            appendLengthDelimitedField(&valueBody, fieldNumber: 1, payload: Data(value.utf8))
            appendLengthDelimitedField(&layerBody, fieldNumber: 4, payload: valueBody)
        }

        var tileBody = Data()
        appendLengthDelimitedField(&tileBody, fieldNumber: 3, payload: layerBody)
        return tileBody
    }

    private func randomValue(_ generator: inout SplitMix64) -> VectorTile_Tile.Value {
        var value = VectorTile_Tile.Value()
        switch generator.next() % 7 {
        case 0: value.stringValue = "value_\(generator.next() % 1000)"
        case 1: value.floatValue = Float(generator.next() % 100_000) / 8.0
        case 2: value.doubleValue = Double(generator.next() % 1_000_000) / 16.0
        case 3: value.intValue = Int64(bitPattern: generator.next())
        case 4: value.uintValue = generator.next()
        case 5: value.sintValue = Int64(bitPattern: generator.next())
        default: value.boolValue = generator.next() % 2 == 0
        }
        return value
    }

    private func appendZigZagDelta(_ geometry: inout [UInt32],
                                   _ cursor: inout (x: Int32, y: Int32),
                                   _ generator: inout SplitMix64) {
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

    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

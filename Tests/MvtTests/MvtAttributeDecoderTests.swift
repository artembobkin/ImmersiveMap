// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import MvtTestSupport
import XCTest

final class MvtAttributeDecoderTests: XCTestCase {
    func testPairsResolveThroughTheLayerTables() throws {
        let data = makeTile(tags: [0, 1, 1, 0], keys: ["kind", "name"], values: [.string("park"), .string("Green")])
        let decoded = try MvtTileDecoder.decode(data: data)
        let layer = try XCTUnwrap(decoded.layers.first)
        let feature = try XCTUnwrap(layer.features.first)

        let attributes = MvtAttributeDecoder.attributes(of: feature, in: layer, data: data)
        XCTAssertEqual(attributes, ["kind": .string("Green"), "name": .string("park")])
    }

    func testDanglingTagIndexIsIgnored() throws {
        // An odd number of tag integers leaves a dangling key index; attribute
        // decoding drops it and keeps the complete pairs.
        let data = makeTile(tags: [0, 0, 1], keys: ["kept", "dangling"], values: [.string("value")])
        let decoded = try MvtTileDecoder.decode(data: data)
        let layer = try XCTUnwrap(decoded.layers.first)
        let feature = try XCTUnwrap(layer.features.first)

        let attributes = MvtAttributeDecoder.attributes(of: feature, in: layer, data: data)
        XCTAssertEqual(attributes, ["kept": .string("value")])
    }

    func testIndexPastTheTablesDropsThePair() throws {
        let data = makeTile(tags: [0, 0, 5, 0, 0, 9], keys: ["kept"], values: [.string("value")])
        let decoded = try MvtTileDecoder.decode(data: data)
        let layer = try XCTUnwrap(decoded.layers.first)
        let feature = try XCTUnwrap(layer.features.first)

        let attributes = MvtAttributeDecoder.attributes(of: feature, in: layer, data: data)
        XCTAssertEqual(attributes, ["kept": .string("value")])
    }

    func testMaterializedTagsReadTheSameAsThePackedRange() throws {
        let data = makeTile(tags: [0, 0, 1, 1], keys: ["a", "b"], values: [.int(1), .int(2)])
        let decoded = try MvtTileDecoder.decode(data: data)
        var layer = try XCTUnwrap(decoded.layers.first)
        var feature = try XCTUnwrap(layer.features.first)

        let fromRange = MvtAttributeDecoder.attributes(of: feature, in: layer, data: data)
        feature.tags = .values(feature.tags.materializedValues(data: data))
        layer.features[0] = feature
        let fromValues = MvtAttributeDecoder.attributes(of: feature, in: layer, data: data)
        XCTAssertEqual(fromRange, fromValues)
        XCTAssertEqual(fromRange, ["a": .int(1), "b": .int(2)])
    }

    private func makeTile(tags: [UInt32], keys: [String], values: [MvtValue]) -> Data {
        let feature = MvtFeatureMessage(tags: tags, type: .point, geometry: [9, 0, 0])
        let layer = MvtLayerMessage(name: "layer", features: [feature], keys: keys, values: values)
        return MvtTileMessage(layers: [layer]).serializedData()
    }
}

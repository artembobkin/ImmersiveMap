// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import MvtTestSupport
import XCTest

final class MvtLayerMergeTests: XCTestCase {
    private let targets: Set<String> = ["target", "other-target"]

    func testTheSourceFeaturesJoinTheTargetWithTheirAttributesRebased() throws {
        let data = tile([
            MvtLayerMessage(name: "first", features: [feature(tags: [0, 0])], keys: ["kind"], values: [.string("lake")]),
            MvtLayerMessage(name: "target", features: [feature(tags: [0, 0, 1, 1])],
                            keys: ["class", "name"], values: [.string("primary"), .string("Main")]),
            MvtLayerMessage(name: "source", features: [feature(tags: [0, 0]), feature(tags: [1, 1, 0, 0])],
                            keys: ["subclass", "paint"], values: [.string("carriageway"), .string("white")]),
        ])
        let merged = try MvtTileDecoder.decode(data: data).merging(layersNamed: "source", intoFirstLayerNamed: targets)

        XCTAssertEqual(merged.layers.map(\.name), ["first", "target"], "the source is gone and the target kept its place")
        let target = merged.layers[1]
        XCTAssertEqual(target.keys, ["class", "name", "subclass", "paint"])
        XCTAssertEqual(target.values, [.string("primary"), .string("Main"), .string("carriageway"), .string("white")])
        let attributes = target.features.map { MvtAttributeDecoder.attributes(of: $0, in: target, data: data) }
        XCTAssertEqual(attributes[0], ["class": .string("primary"), "name": .string("Main")])
        XCTAssertEqual(attributes[1], ["subclass": .string("carriageway")])
        XCTAssertEqual(attributes[2], ["paint": .string("white"), "subclass": .string("carriageway")])
        XCTAssertEqual(target.features[1].tags.materializedValues(data: data), [2, 2], "re-based onto the target's tables")
    }

    func testTheGeometryStaysAByteRangeIntoThePayload() throws {
        let data = tile([
            MvtLayerMessage(name: "target", features: [feature(tags: [])]),
            MvtLayerMessage(name: "source", features: [feature(tags: [], geometry: [9, 4, 6])]),
        ])
        let merged = try MvtTileDecoder.decode(data: data).merging(layersNamed: "source", intoFirstLayerNamed: targets)
        let joined = merged.layers[0].features[1]
        guard case .range = joined.geometry else {
            return XCTFail("the merge must not materialize geometry")
        }
        let points = MvtGeometryDecoder.decodePoints(joined.geometry, in: data)
        XCTAssertEqual(points.map { [$0.x, $0.y] }, [[2, 3]])
        XCTAssertEqual(joined.tags.materializedValues(data: data), [], "a feature without tags stays without")
    }

    func testEverySourceLayerJoinsTheFirstTargetOnly() throws {
        let data = tile([
            MvtLayerMessage(name: "source", features: [feature(tags: [])]),
            MvtLayerMessage(name: "other-target", features: [feature(tags: [])]),
            MvtLayerMessage(name: "target", features: [feature(tags: [])]),
            MvtLayerMessage(name: "source", features: [feature(tags: []), feature(tags: [])]),
        ])
        let merged = try MvtTileDecoder.decode(data: data).merging(layersNamed: "source", intoFirstLayerNamed: targets)
        XCTAssertEqual(merged.layers.map(\.name), ["other-target", "target"])
        XCTAssertEqual(merged.layers.map(\.features.count), [4, 1])
    }

    func testASourceWithAnotherExtentStaysALayerOfItsOwn() throws {
        let data = tile([
            MvtLayerMessage(name: "target", features: [feature(tags: [])], extent: 4096),
            MvtLayerMessage(name: "source", features: [feature(tags: [])], extent: 8192),
        ])
        let merged = try MvtTileDecoder.decode(data: data).merging(layersNamed: "source", intoFirstLayerNamed: targets)
        XCTAssertEqual(merged.layers.map(\.name), ["target", "source"])
        XCTAssertEqual(merged.layers[0].features.count, 1)
    }

    func testWithoutATargetOrASourceTheTileIsUntouched() throws {
        let noTarget = tile([
            MvtLayerMessage(name: "first", features: [feature(tags: [])]),
            MvtLayerMessage(name: "source", features: [feature(tags: [])]),
        ])
        let merged = try MvtTileDecoder.decode(data: noTarget).merging(layersNamed: "source", intoFirstLayerNamed: targets)
        XCTAssertEqual(merged.layers.map(\.name), ["first", "source"])

        let noSource = tile([MvtLayerMessage(name: "target", features: [feature(tags: [])])])
        let same = try MvtTileDecoder.decode(data: noSource).merging(layersNamed: "source", intoFirstLayerNamed: targets)
        XCTAssertEqual(same.layers.map(\.name), ["target"])
    }

    private func tile(_ layers: [MvtLayerMessage]) -> Data {
        MvtTileMessage(layers: layers).serializedData()
    }

    private func feature(tags: [UInt32], geometry: [UInt32] = [9, 0, 0]) -> MvtFeatureMessage {
        MvtFeatureMessage(tags: tags, type: .point, geometry: geometry)
    }
}

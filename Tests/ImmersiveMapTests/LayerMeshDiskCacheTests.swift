// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// A layer's mesh on disk: the file it is written as, and the cache that
/// keeps the files.
final class LayerMeshFileTests: XCTestCase {
    private static func mesh() -> LayerMeshData {
        let ring = [GeoCoordinate(latitude: 55.7, longitude: 37.5), GeoCoordinate(latitude: 55.7, longitude: 37.7),
                    GeoCoordinate(latitude: 55.8, longitude: 37.7), GeoCoordinate(latitude: 55.8, longitude: 37.5)]
        let content = LayerSourceContent(polygons: [ImmersiveMapPolygon(exterior: ring)],
                                         polylines: [],
                                         points: [ImmersiveMapPoint(coordinate: GeoCoordinate(latitude: -33.9, longitude: 151.2))])
        return LayerMeshBuilder.build(layer: ImmersiveMapLayer(source: "shapes"), content: content)
    }

    private static func bytes<Element>(_ values: [Element]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    func testAMeshComesBackFromItsFileAsItWas() throws {
        let mesh = Self.mesh()
        let file = LayerMeshFile.encode(mesh)

        let prefixSize = try XCTUnwrap(LayerMeshFile.prefixSize(ofHeader: file.prefix(LayerMeshFile.headerSize)))
        let contents = try XCTUnwrap(LayerMeshFile.decode(header: file.prefix(prefixSize), fileSize: file.count))

        XCTAssertEqual(contents.chunks, mesh.chunks)
        XCTAssertEqual(contents.chunks.count, 2)
        XCTAssertEqual(file.subdata(in: contents.fillVertices), Self.bytes(mesh.fillVertices))
        XCTAssertEqual(file.subdata(in: contents.fillIndices), Self.bytes(mesh.fillIndices))
        XCTAssertEqual(file.subdata(in: contents.lineSegments), Self.bytes(mesh.lineSegments))
        XCTAssertFalse(mesh.lineSegments.isEmpty)
        XCTAssertEqual(file.subdata(in: contents.discs), Self.bytes(mesh.discs))
        for block in contents.blocks {
            XCTAssertEqual(block.lowerBound % 16, 0)
        }
    }

    func testAnEmptyMeshIsAFileOfItsHeaderAlone() throws {
        let file = LayerMeshFile.encode(LayerMeshData())
        let contents = try XCTUnwrap(LayerMeshFile.decode(header: file, fileSize: file.count))
        XCTAssertTrue(contents.chunks.isEmpty)
        XCTAssertTrue(contents.blocks.allSatisfy(\.isEmpty))
    }

    func testADamagedFileIsNotAMesh() {
        let file = LayerMeshFile.encode(Self.mesh())

        var otherVersion = file
        otherVersion[4] = 0xFF
        XCTAssertNil(LayerMeshFile.decode(header: otherVersion, fileSize: otherVersion.count))
        XCTAssertNil(LayerMeshFile.prefixSize(ofHeader: otherVersion))

        XCTAssertNil(LayerMeshFile.decode(header: file, fileSize: file.count - 8), "A file cut short")
        XCTAssertNil(LayerMeshFile.decode(header: file.prefix(20), fileSize: file.count))
        XCTAssertNil(LayerMeshFile.decode(header: Data("not a mesh at all".utf8), fileSize: 17))
    }
}

final class LayerMeshDiskCacheTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LayerMeshDiskCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func key(_ layer: ImmersiveMapLayer = ImmersiveMapLayer(source: "zones")) -> LayerMeshKey {
        layer.meshKey(sourceRevision: 1)
    }

    private func writeSource(_ text: String) throws -> URL {
        let url = base.appendingPathComponent("zones.geojson")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testAnEntryGoesByItsFileAndItsStyles() throws {
        let cache = LayerMeshDiskCache(limitBytes: 1_000_000, baseDirectory: base)
        let source = try writeSource("one")
        let name = try XCTUnwrap(cache.entryName(identity: .file(source), key: key()))

        XCTAssertEqual(cache.entryName(identity: .file(source), key: key()), name)
        XCTAssertEqual(cache.entryName(identity: .file(source), key: ImmersiveMapLayer(source: "zones").meshKey(sourceRevision: 9)),
                       name, "The same file registered again in another launch is the same entry")

        var restyled = ImmersiveMapLayer(source: "zones")
        restyled.polygonStyle.strokeWidthPoints = 7
        XCTAssertNotEqual(cache.entryName(identity: .file(source), key: key(restyled)), name)

        _ = try writeSource("another, longer")
        XCTAssertNotEqual(cache.entryName(identity: .file(source), key: key()), name, "A changed file is another entry")

        XCTAssertNil(cache.entryName(identity: .file(base.appendingPathComponent("missing.geojson")), key: key()))
    }

    func testAnEntryOfDataInMemoryGoesByTheIdentityItWasGiven() throws {
        let cache = LayerMeshDiskCache(limitBytes: 1_000_000, baseDirectory: base)
        let name = try XCTUnwrap(cache.entryName(identity: .named("v1"), key: key()))

        XCTAssertEqual(cache.entryName(identity: .named("v1"), key: ImmersiveMapLayer(source: "zones").meshKey(sourceRevision: 9)),
                       name, "The same identity in another launch is the same entry")
        XCTAssertNotEqual(cache.entryName(identity: .named("v2"), key: key()), name)
        XCTAssertNotEqual(cache.entryName(identity: .named("v1"), key: key(ImmersiveMapLayer(source: "parks"))), name,
                          "Two sources may use the same identity")
    }

    func testAStoredEntryIsFoundAndARemovedOneIsNot() {
        let cache = LayerMeshDiskCache(limitBytes: 1_000_000, baseDirectory: base)
        XCTAssertNil(cache.existingFile(named: "a.layermesh"))

        cache.store(Data(repeating: 1, count: 100), named: "a.layermesh")
        let file = cache.existingFile(named: "a.layermesh")
        XCTAssertEqual(file.flatMap { try? Data(contentsOf: $0) }, Data(repeating: 1, count: 100))

        cache.remove(named: "a.layermesh")
        XCTAssertNil(cache.existingFile(named: "a.layermesh"))
    }

    func testOverTheLimitTheEntryUsedLongestAgoIsDeleted() throws {
        let cache = LayerMeshDiskCache(limitBytes: 250, baseDirectory: base)
        cache.store(Data(count: 100), named: "old.layermesh")
        cache.store(Data(count: 100), named: "new.layermesh")
        // Used an hour ago and a minute ago, whatever the clock's grain.
        for (name, age) in [("old.layermesh", 3600.0), ("new.layermesh", 60.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                                  ofItemAtPath: cache.directory.appendingPathComponent(name).path)
        }

        cache.store(Data(count: 100), named: "newest.layermesh")

        XCTAssertEqual(Set(cache.entries().map(\.url.lastPathComponent)), ["new.layermesh", "newest.layermesh"])
    }

    func testACacheWithNoRoomKeepsNothing() {
        let off = LayerMeshDiskCache(limitBytes: 0, baseDirectory: base)
        off.store(Data(count: 10), named: "a.layermesh")
        XCTAssertFalse(off.isEnabled)
        XCTAssertTrue(off.entries().isEmpty)

        let small = LayerMeshDiskCache(limitBytes: 50, baseDirectory: base)
        small.store(Data(count: 100), named: "large.layermesh")
        XCTAssertTrue(small.entries().isEmpty, "A mesh larger than the limit is not kept")
    }
}

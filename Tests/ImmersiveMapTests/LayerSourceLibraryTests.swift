// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The registered sources of the app's layers: read when a frame needs
/// their shapes, bounded by the input limit, and let go when nothing does.
final class LayerSourceLibraryTests: XCTestCase {
    /// A map that draws from the library, as `LayerMeshStore` is.
    private final class Client {}

    /// A source of `count` points, each of one fixed size, told apart by
    /// their number.
    private static func points(_ count: Int) -> LayerSourceData {
        .shapes(polygons: [],
                polylines: [],
                points: (0 ..< count).map { ImmersiveMapPoint(coordinate: GeoCoordinate(latitude: 0, longitude: Double($0))) },
                identity: "\(count) points")
    }

    private static let pointSize = MemoryLayout<ImmersiveMapPoint>.stride

    /// Draws `drawn` as one frame of `client` does, building a mesh from
    /// each, and waits until none of them is on its way: a frame for each
    /// change the library reports.
    private func settle(_ library: LayerSourceLibrary, client: Client, drawing drawn: [String]) async {
        let changes = AsyncStream<Void> { continuation in
            library.addClient(client) { continuation.yield() }
        }
        var iterator = changes.makeAsyncIterator()
        while Self.frame(library, client: client, drawing: drawn).values.contains(where: \.isLoading) {
            _ = await iterator.next()
        }
    }

    /// One frame of `client` that draws `drawn` and builds from each.
    @discardableResult
    private static func frame(_ library: LayerSourceLibrary,
                              client: Client,
                              drawing drawn: [String]) -> [String: LayerSourceLibrary.State] {
        library.states(of: Set(drawn), drawn: drawn, building: Set(drawn), client: client)
    }

    func testASourceIsReadOnlyWhenAFrameDrawsIt() async {
        let library = LayerSourceLibrary(limitBytes: 1_000_000)
        let client = Client()
        library.register("a", Self.points(10))
        library.register("b", Self.points(10))
        XCTAssertEqual(library.loadedBytes, 0, "A registered source costs nothing")

        await settle(library, client: client, drawing: ["a"])

        XCTAssertTrue(library.isLoaded("a"))
        XCTAssertFalse(library.isLoaded("b"), "A source no layer draws is not read")
        XCTAssertEqual(library.loadedBytes, 10 * Self.pointSize)
    }

    func testRegisteringTheSameDataAgainChangesNothing() async {
        let library = LayerSourceLibrary(limitBytes: 1_000_000)
        let client = Client()
        library.register("a", Self.points(10))
        await settle(library, client: client, drawing: ["a"])
        let revision = Self.frame(library, client: client, drawing: ["a"])["a"]?.revision

        library.register("a", Self.points(10))
        XCTAssertEqual(Self.frame(library, client: client, drawing: ["a"])["a"]?.revision, revision)
        XCTAssertTrue(library.isLoaded("a"), "The shapes that were read are kept")

        library.register("a", Self.points(11))
        XCTAssertFalse(library.isLoaded("a"), "Other data is read anew")
        XCTAssertNotEqual(library.states(of: ["a"], drawn: [], client: client)["a"]?.revision, revision)
    }

    func testOverTheLimitTheSourceDrawnLastIsRefused() async {
        let library = LayerSourceLibrary(limitBytes: 15 * Self.pointSize)
        let client = Client()
        library.register("first", Self.points(10))
        library.register("second", Self.points(10))

        await settle(library, client: client, drawing: ["first", "second"])

        XCTAssertTrue(library.isLoaded("first"))
        XCTAssertFalse(library.isLoaded("second"))
        XCTAssertEqual(library.failure(of: "second"),
                       .limitExceeded(bytes: 10 * Self.pointSize, limit: 15 * Self.pointSize))
        XCTAssertNil(library.failure(of: "first"))
    }

    func testTheShapesNothingNeedsAreLetGo() async {
        let library = LayerSourceLibrary(limitBytes: 1_000_000)
        let client = Client()
        library.register("first", Self.points(10))
        library.register("second", Self.points(10))
        await settle(library, client: client, drawing: ["first"])

        // The frame moves on to the second source.
        await settle(library, client: client, drawing: ["second"])
        XCTAssertTrue(library.isLoaded("second"))
        XCTAssertFalse(library.isLoaded("first"))

        // Its mesh is built: the frame draws it and builds from nothing.
        _ = library.states(of: ["second"], drawn: ["second"], client: client)
        XCTAssertFalse(library.isLoaded("second"), "A drawn layer needs its mesh alone")
        XCTAssertEqual(library.loadedBytes, 0)
    }

    func testTheShapesOfWhatIsDrawnAreKeptWhileTapsAreListenedTo() async {
        let library = LayerSourceLibrary(limitBytes: 1_000_000)
        let client = Client()
        library.register("shown", Self.points(10))
        library.shapesWanted = true
        await settle(library, client: client, drawing: ["shown"])

        _ = library.states(of: ["shown"], drawn: ["shown"], client: client)
        XCTAssertTrue(library.isLoaded("shown"), "A tap is tested against the shapes of what is drawn")

        library.shapesWanted = false
        _ = library.states(of: ["shown"], drawn: ["shown"], client: client)
        XCTAssertFalse(library.isLoaded("shown"))
    }

    func testARefusedSourceIsReadAgainOnceAnotherStopsBeingDrawn() async {
        let library = LayerSourceLibrary(limitBytes: 15 * Self.pointSize)
        let client = Client()
        library.register("first", Self.points(10))
        library.register("second", Self.points(10))
        await settle(library, client: client, drawing: ["first", "second"])
        XCTAssertNotNil(library.failure(of: "second"))

        await settle(library, client: client, drawing: ["second"])

        XCTAssertTrue(library.isLoaded("second"))
        XCTAssertNil(library.failure(of: "second"))
    }

    func testASourceIsToldApartByItsFileOrByTheIdentityItWasGiven() {
        let library = LayerSourceLibrary(limitBytes: 1_000_000)
        let client = Client()
        let url = URL(fileURLWithPath: "/nonexistent/layer.geojson")
        library.register("file", .geoJSONFile(url))
        library.register("memory", .geoJSON(Data("one".utf8), identity: "v1"))

        var states = library.states(of: ["file", "memory"], drawn: [], client: client)
        XCTAssertEqual(states["file"]?.identity, .file(url))
        XCTAssertEqual(states["memory"]?.identity, .named("v1"))
        let revision = states["memory"]?.revision

        // The data is never looked into: the same identity is the same
        // data, whatever the bytes, and another identity is other data.
        library.register("memory", .geoJSON(Data("two".utf8), identity: "v1"))
        states = library.states(of: ["memory"], drawn: [], client: client)
        XCTAssertEqual(states["memory"]?.revision, revision)

        library.register("memory", .geoJSON(Data("two".utf8), identity: "v2"))
        states = library.states(of: ["memory"], drawn: [], client: client)
        XCTAssertNotEqual(states["memory"]?.revision, revision)
    }

    func testAnUnreadableFileAndABadDocumentAreReported() async {
        let library = LayerSourceLibrary(limitBytes: 1_000_000)
        let client = Client()
        library.register("missing", .geoJSONFile(URL(fileURLWithPath: "/nonexistent/layer.geojson")))
        library.register("bad", .geoJSON(Data("not json".utf8), identity: "bad"))

        await settle(library, client: client, drawing: ["missing", "bad"])

        guard case .unreadableFile = library.failure(of: "missing") else {
            return XCTFail("A missing file is unreadable: \(String(describing: library.failure(of: "missing")))")
        }
        XCTAssertEqual(library.failure(of: "bad"), .invalidGeoJSON(.invalidJSON))
    }

    func testAGeoJSONDocumentIsReadIntoItsShapes() async {
        let library = LayerSourceLibrary(limitBytes: 1_000_000)
        let client = Client()
        library.register("point", .geoJSON(Data(#"{"type": "Point", "coordinates": [37.6, 55.7]}"#.utf8), identity: "point"))

        await settle(library, client: client, drawing: ["point"])

        let content = Self.frame(library, client: client, drawing: ["point"])["point"]?.content
        XCTAssertEqual(content?.points.map(\.coordinate), [GeoCoordinate(latitude: 55.7, longitude: 37.6)])
    }
}

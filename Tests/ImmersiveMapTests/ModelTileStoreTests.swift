// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// The model tile store: a wanted tile loads and is answered on a later
/// frame, an empty tile is asked for once, a failed one again after a
/// pause, and the tiles the camera has left go when the budget is passed.
/// The tile bytes come from a closure, so nothing here reaches a network.
final class ModelTileStoreTests: XCTestCase {
    private final class CountingEventSink: RenderFrameEventSink, @unchecked Sendable {
        private let count = Locked(0)

        var invalidationCount: Int {
            count.withLock { $0 }
        }

        func invalidate(_ reason: RenderInvalidationReason) {
            count.withLock { $0 += 1 }
        }

        func applyActivityState(_ state: RenderActivityState) {}
        func completeSceneModelPathAnimations(_: [SceneModelPathAnimationResult]) {}
        func updateAvatarSelectionSnapshot(_ snapshot: AvatarSelectionSnapshot) {}
        func updateSceneModelSelectionSnapshot(_ snapshot: SceneModelSelectionSnapshot) {}
        func updateDebugOverlayHUDSnapshot(_ snapshot: DebugOverlayHUDSnapshot?) {}
        func updateMarkerProjectionSnapshot(_ snapshot: MarkerProjectionSnapshot) {}
    }

    private static let tileA = Tile(x: 9904, y: 5121, z: 14)
    private static let tileB = Tile(x: 9905, y: 5121, z: 14)

    private func makeDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard ModelTileMesh.isSupported(device: device) else {
            throw XCTSkip("This GPU has no ASTC textures")
        }
        return device
    }

    private static func tileData(_ tile: Tile, model: ModelTileFixture.Model = .init(id: "model")) -> Data {
        var fixture = ModelTileFixture()
        fixture.x = tile.x
        fixture.y = tile.y
        fixture.models = [model]
        return fixture.serialized()
    }

    /// Waits until the store has reported `count` loads that ended.
    private func waitForInvalidations(_ count: Int, sink: CountingEventSink) async throws {
        let deadline = Date().addingTimeInterval(10)
        while sink.invalidationCount < count {
            guard Date() < deadline else {
                return XCTFail("The store reported \(sink.invalidationCount) ended loads, expected \(count)")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testAWantedTileLoadsAndIsAnsweredOnALaterFrame() async throws {
        let device = try makeDevice()
        let sink = CountingEventSink()
        let schema = ImmersiveMapSettings.default.mapStyle.schema
        var fixture = ModelTileFixture()
        fixture.models = [ModelTileFixture.Model(id: "bolshoi", replaced: [(2, 84_653_688, 14), (3, 3_334_755, 15), (2, 84_653_688, 15)]),
                          ModelTileFixture.Model(id: "okhotny-ryad", cutsIntoGround: true, replaced: [(3, 6_233_742, 15)])]
        let data = fixture.serialized()
        let store = ModelTileStore(device: device,
                                   schema: schema,
                                   costLimitBytes: 1 << 20,
                                   loadTile: { _ in .tile(data, fileURL: nil) })
        store.eventSink = sink

        let first = store.meshes(for: [Self.tileA])
        XCTAssertTrue(first.ready.isEmpty)
        XCTAssertEqual(first.pendingCount, 1)

        try await waitForInvalidations(1, sink: sink)
        let second = store.meshes(for: [Self.tileA])
        XCTAssertEqual(second.pendingCount, 0)
        let mesh = try XCTUnwrap(second.ready.first)
        XCTAssertEqual(mesh.tile, Self.tileA)
        XCTAssertEqual(mesh.indexCount, 6)
        XCTAssertEqual(mesh.mergedIndexCount, 3, "one call draws the model that needs no state of its own")
        XCTAssertEqual(mesh.groundCutModels.count, 1)
        XCTAssertEqual(mesh.groundCutModels[0].indexByteOffset, 3 * MemoryLayout<UInt32>.stride)
        XCTAssertEqual(mesh.groundCutModels[0].indexCount, 3)
        XCTAssertEqual(mesh.boundsMaximum, SIMD3(10, 20, 0))
        XCTAssertEqual(mesh.replacedBuildingIDs,
                       [14: Set([schema.tileFeatureID(of: .way(84_653_688))].compactMap { $0 }),
                        15: Set([schema.tileFeatureID(of: .relation(3_334_755)),
                                 schema.tileFeatureID(of: .way(84_653_688)),
                                 schema.tileFeatureID(of: .relation(6_233_742))].compactMap { $0 })],
                       "the tile hides every building its models list, in the map tiles of the zoom listed")
        XCTAssertEqual(mesh.texture.textureType, .type2DArray)
        XCTAssertEqual(mesh.texture.pixelFormat, .astc_8x8_ldr)
        XCTAssertEqual(mesh.texture.mipmapLevelCount, 5)
        XCTAssertEqual(store.residentCostInBytes, mesh.costInBytes)
    }

    /// Most of the map has no models: a tile the archive does not hold is
    /// remembered, not asked for on every frame.
    func testAnEmptyTileIsAskedForOnce() async throws {
        let device = try makeDevice()
        let sink = CountingEventSink()
        let loads = Locked(0)
        let store = ModelTileStore(device: device,
                                   schema: ImmersiveMapSettings.default.mapStyle.schema,
                                   costLimitBytes: 1 << 20,
                                   loadTile: { _ in
                                       loads.withLock { $0 += 1 }
                                       return .missing
                                   })
        store.eventSink = sink

        XCTAssertEqual(store.meshes(for: [Self.tileA]).pendingCount, 1)
        try await waitForInvalidations(1, sink: sink)
        for _ in 0..<3 {
            let answer = store.meshes(for: [Self.tileA])
            XCTAssertTrue(answer.ready.isEmpty)
            XCTAssertEqual(answer.pendingCount, 0)
        }
        XCTAssertEqual(loads.withLock { $0 }, 1)
    }

    /// The tiles a frame wants stay whatever they cost. One the camera has
    /// left goes when the budget is passed.
    func testATileLeftBehindIsReleasedPastTheBudget() async throws {
        let device = try makeDevice()
        let sink = CountingEventSink()
        let store = ModelTileStore(device: device,
                                   schema: ImmersiveMapSettings.default.mapStyle.schema,
                                   costLimitBytes: 1,
                                   loadTile: { tile in .tile(Self.tileData(tile), fileURL: nil) })
        store.eventSink = sink

        _ = store.meshes(for: [Self.tileA, Self.tileB])
        try await waitForInvalidations(2, sink: sink)
        XCTAssertEqual(store.meshes(for: [Self.tileA, Self.tileB]).ready.count, 2,
                       "both are wanted, so both stay over the budget")

        _ = store.meshes(for: [Self.tileB])
        store.evict()
        XCTAssertEqual(store.residentTiles, [Self.tileB])
        XCTAssertEqual(store.meshes(for: [Self.tileB]).ready.count, 1)
    }

    func testAMemoryWarningReleasesWhatTheLastFrameDidNotWant() async throws {
        let device = try makeDevice()
        let sink = CountingEventSink()
        let store = ModelTileStore(device: device,
                                   schema: ImmersiveMapSettings.default.mapStyle.schema,
                                   costLimitBytes: 1 << 30,
                                   loadTile: { tile in .tile(Self.tileData(tile), fileURL: nil) })
        store.eventSink = sink

        _ = store.meshes(for: [Self.tileA, Self.tileB])
        try await waitForInvalidations(2, sink: sink)
        _ = store.meshes(for: [Self.tileA])
        store.evict()
        XCTAssertEqual(store.residentTiles, [Self.tileA, Self.tileB], "inside the budget nothing goes")

        store.handleMemoryWarning()
        XCTAssertEqual(store.residentTiles, [Self.tileA])
    }

    /// A tile that could not be fetched waits out a pause, and is asked for
    /// again once the pause has passed and a frame still wants it.
    func testAFailedLoadIsAskedForAgainAfterAPause() async throws {
        struct Unreachable: Error {}
        let device = try makeDevice()
        let sink = CountingEventSink()
        let loads = Locked(0)
        let clock = Locked<TimeInterval>(1_000)
        let store = ModelTileStore(device: device,
                                   schema: ImmersiveMapSettings.default.mapStyle.schema,
                                   costLimitBytes: 1 << 20,
                                   loadTile: { tile in
                                       let attempt = loads.withLock { count -> Int in
                                           count += 1
                                           return count
                                       }
                                       if attempt == 1 {
                                           throw Unreachable()
                                       }
                                       return .tile(Self.tileData(tile), fileURL: nil)
                                   },
                                   now: { clock.withLock { $0 } })
        store.eventSink = sink

        _ = store.meshes(for: [Self.tileA])
        try await waitForInvalidations(1, sink: sink)
        let duringPause = store.meshes(for: [Self.tileA])
        XCTAssertTrue(duringPause.ready.isEmpty)
        XCTAssertEqual(duringPause.pendingCount, 0, "a tile waiting out its pause is not on its way")
        XCTAssertEqual(loads.withLock { $0 }, 1)

        clock.withLock { $0 += ModelTileStore.retryBaseDelay + 1 }
        XCTAssertEqual(store.meshes(for: [Self.tileA]).pendingCount, 1)
        try await waitForInvalidations(2, sink: sink)
        XCTAssertEqual(store.meshes(for: [Self.tileA]).ready.count, 1)
        XCTAssertEqual(loads.withLock { $0 }, 2)
    }

    /// Bytes that are not a tile are not asked for again: the same bytes
    /// would come back. The cached copy is dropped.
    func testATileThatCannotBeReadIsDroppedAndNotAskedForAgain() async throws {
        let device = try makeDevice()
        let sink = CountingEventSink()
        let loads = Locked(0)
        let discarded = Locked<[Tile]>([])
        let store = ModelTileStore(device: device,
                                   schema: ImmersiveMapSettings.default.mapStyle.schema,
                                   costLimitBytes: 1 << 20,
                                   loadTile: { _ in
                                       loads.withLock { $0 += 1 }
                                       return .tile(Data(repeating: 7, count: 512), fileURL: nil)
                                   },
                                   discardCachedTile: { tile in discarded.withLock { $0.append(tile) } })
        store.eventSink = sink

        _ = store.meshes(for: [Self.tileA])
        try await waitForInvalidations(1, sink: sink)
        let answer = store.meshes(for: [Self.tileA])
        XCTAssertTrue(answer.ready.isEmpty)
        XCTAssertEqual(answer.pendingCount, 0)
        XCTAssertEqual(loads.withLock { $0 }, 1)
        XCTAssertEqual(discarded.withLock { $0 }, [Self.tileA])
    }

    /// A tile whose bytes say they are another tile is not drawn in this
    /// one's place.
    func testATileOfOtherCoordinatesIsNotAccepted() async throws {
        let device = try makeDevice()
        let sink = CountingEventSink()
        let store = ModelTileStore(device: device,
                                   schema: ImmersiveMapSettings.default.mapStyle.schema,
                                   costLimitBytes: 1 << 20,
                                   loadTile: { _ in .tile(Self.tileData(Self.tileB), fileURL: nil) })
        store.eventSink = sink

        _ = store.meshes(for: [Self.tileA])
        try await waitForInvalidations(1, sink: sink)
        XCTAssertTrue(store.meshes(for: [Self.tileA]).ready.isEmpty)
        XCTAssertTrue(store.residentTiles.isEmpty)
    }

    /// The tiles load a few at a time, in the order the frame names them.
    func testNoMoreThanTheLimitLoadAtOnce() async throws {
        let device = try makeDevice()
        let sink = CountingEventSink()
        let started = Locked<[Tile]>([])
        let gateIsOpen = Locked(false)
        let store = ModelTileStore(device: device,
                                   schema: ImmersiveMapSettings.default.mapStyle.schema,
                                   costLimitBytes: 1 << 20,
                                   loadTile: { tile in
                                       started.withLock { $0.append(tile) }
                                       while gateIsOpen.withLock({ $0 }) == false {
                                           try await Task.sleep(nanoseconds: 2_000_000)
                                       }
                                       return .missing
                                   })
        store.eventSink = sink
        let wanted = (0..<6).map { Tile(x: 9900 + $0, y: 5121, z: 14) }

        XCTAssertEqual(store.meshes(for: wanted).pendingCount, 6)
        XCTAssertEqual(store.meshes(for: wanted).pendingCount, 6, "asking again starts nothing more")
        let deadline = Date().addingTimeInterval(10)
        while started.withLock({ $0.count }) < ModelTileStore.maximumConcurrentLoads, Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(Set(started.withLock { $0 }), Set(wanted.prefix(ModelTileStore.maximumConcurrentLoads)))

        gateIsOpen.withLock { $0 = true }
        try await waitForInvalidations(ModelTileStore.maximumConcurrentLoads, sink: sink)
        XCTAssertEqual(store.meshes(for: wanted).pendingCount, 2, "the two that waited start now")
        try await waitForInvalidations(6, sink: sink)
        XCTAssertEqual(store.meshes(for: wanted).pendingCount, 0)
        XCTAssertEqual(Set(started.withLock { $0 }), Set(wanted))
    }

    /// A tile whose bulk blocks are zeroed in memory and whole in a file:
    /// what only a load from the file can fill.
    private func writeTileFile(_ tile: Data) throws -> (fileURL: URL, hollow: Data, contents: ModelTileContents) {
        let contents = try ModelTileContents(decoding: tile)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelTileStoreTests-\(UUID().uuidString).immt")
        try tile.write(to: fileURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        var hollow = tile
        hollow.replaceSubrange(contents.vertexRange.lowerBound..<tile.count,
                               with: Data(count: tile.count - contents.vertexRange.lowerBound))
        return (fileURL, hollow, contents)
    }

    private func requireIOQueue(_ device: MTLDevice) throws {
#if targetEnvironment(simulator)
        throw XCTSkip("The simulator has no IO command queue")
#else
        guard MetalIOCommandQueues.shared(for: device) != nil else {
            throw XCTSkip("This device has no IO command queue")
        }
#endif
    }

    /// A tile from the disk cache is loaded from its file straight into
    /// the buffers and the texture: the bytes in memory are read only as
    /// far as the tables.
    func testATileFromTheDiskIsLoadedFromItsFile() async throws {
        let device = try makeDevice()
        try requireIOQueue(device)
        let tile = Self.tileData(Self.tileA)
        let file = try writeTileFile(tile)

        let mesh = try await ModelTileMesh.make(contents: file.contents,
                                                data: file.hollow,
                                                fileURL: file.fileURL,
                                                device: device,
                                                schema: ProtomapsBasemapSchema())

        XCTAssertEqual(Data(bytes: mesh.vertexBuffer.contents(), count: file.contents.vertexRange.count),
                       tile.subdata(in: file.contents.vertexRange))
        XCTAssertEqual(Data(bytes: mesh.indexBuffer.contents(), count: file.contents.indexRange.count),
                       tile.subdata(in: file.contents.indexRange))
        var texture = Data()
        for level in 0..<file.contents.texture.mipLevelCount {
            let byteCount = file.contents.texture.layerByteCount(level: level)
            for layer in 0..<file.contents.texture.layerCount {
                var bytes = [UInt8](repeating: 0, count: byteCount)
                mesh.texture.getBytes(&bytes,
                                      bytesPerRow: file.contents.texture.bytesPerRow(level: level),
                                      bytesPerImage: byteCount,
                                      from: MTLRegionMake2D(0, 0,
                                                            max(1, file.contents.texture.width >> level),
                                                            max(1, file.contents.texture.height >> level)),
                                      mipmapLevel: level,
                                      slice: layer)
                texture.append(contentsOf: bytes)
            }
        }
        XCTAssertEqual(texture, tile.subdata(in: file.contents.textureRange))
    }

    /// A file on disk can go bad after it was written. Its geometry is
    /// checked in the buffers it was loaded into, and the store drops the
    /// file so the next request reads the archive again.
    func testACachedFileGoneBadIsRefusedAndDiscarded() async throws {
        let device = try makeDevice()
        try requireIOQueue(device)
        let tile = Self.tileData(Self.tileA)
        var broken = tile
        let contents = try ModelTileContents(decoding: tile)
        broken.replaceSubrange(contents.indexRange.lowerBound..<(contents.indexRange.lowerBound + 4),
                               with: [0xFF, 0xFF, 0xFF, 0x7F])
        let file = try writeTileFile(broken)
        let sink = CountingEventSink()
        let discarded = Locked([Tile]())
        let store = ModelTileStore(device: device,
                                   schema: ProtomapsBasemapSchema(),
                                   costLimitBytes: 1 << 20,
                                   loadTile: { _ in .tile(tile, fileURL: file.fileURL) },
                                   discardCachedTile: { tile in discarded.withLock { $0.append(tile) } })
        store.eventSink = sink

        _ = store.meshes(for: [Self.tileA])
        try await waitForInvalidations(1, sink: sink)

        XCTAssertTrue(store.meshes(for: [Self.tileA]).ready.isEmpty, "a tile that cannot be read draws nothing")
        XCTAssertEqual(discarded.withLock { $0 }, [Self.tileA])
    }
}

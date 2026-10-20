// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import ImageIO
@testable import ImmersiveMap
import UniformTypeIdentifiers
import XCTest

/// What a frame shows while the camera crosses onto the relief and the
/// slots' own tiles are still on their way: the tiles of the zoom before,
/// shown as geometry with their roads, stand in, and keep their look until
/// the slots' own tiles land. Requires the compiled Metal library, so it
/// skips under `swift test` and runs in the xcodebuild workspace suite.
final class GroundReliefStandInOffscreenTests: XCTestCase {
    /// The tile whose centre the camera looks at: a zoom 9 tile, one below
    /// the relief's first tile zoom under the default settings, so its
    /// children are the first targets on the relief.
    private static let parent = Tile(x: 150, y: 192, z: 9)

    @MainActor
    func testAStandInShownAsGeometryKeepsItsRoadsOnTheRelief() async throws {
        let terrain = try makeFlatTerrainDirectory()
        defer { try? FileManager.default.removeItem(at: terrain) }
        var settings = ImmersiveMapSettings.default
            .mapStyle(ProtomapsBasemapMapStyle.default.apply { theme in
                theme.layers.roads.primary = Self.roadColour
                theme.layers.roads.casing = Self.roadColour
                theme.hillshade = .none
            })
        settings.camera.maximumZoom = 22
        settings.scene.starfield.starCount = 0
        settings.scene.shadows.isEnabled = false
        settings.scene.fog.isEnabled = false
        settings.labels.isEnabled = false
        settings = settings.groundRelief(isEnabled: true,
                                         tileURLTemplate: terrain.absoluteString + "{z}/{x}/{y}.png",
                                         exaggeration: 1,
                                         collapseZoom: 30)
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings, size: 768)

        // The zoom 9 tiles, parsed in layers (the flattening starts at the
        // relief's tile zoom 10): a park with two primary roads across it.
        let roads = [
            VectorTileFixture.Feature(id: 2, geometry: .line(points: [(0, 2048), (4096, 2048)]),
                                      properties: ProtomapsRoadSpelling.properties(forClass: "primary")),
            VectorTileFixture.Feature(id: 3, geometry: .line(points: [(2048, 0), (2048, 4096)]),
                                      properties: ProtomapsRoadSpelling.properties(forClass: "primary"))
        ]
        let park = VectorTileFixture.layersTile([
            (layerName: "landuse", features: [VectorTileFixture.Feature(id: 1,
                                                                        geometry: .polygon(ring: [(0, 0), (4096, 0), (4096, 4096), (0, 4096)]),
                                                                        properties: ["kind": "park"])]),
            (layerName: "roads", features: roads)
        ])
        for dx in -1 ... 1 {
            for dy in -1 ... 1 {
                let tile = Tile(x: Self.parent.x + dx, y: Self.parent.y + dy, z: Self.parent.z)
                let loaded = await harness.tileRenderStore.parseTile(tile: tile, data: park)
                XCTAssertTrue(loaded, "The fixture tile must parse")
            }
        }
        let centre = (x: (Double(Self.parent.x) + 0.5) / Double(1 << Self.parent.z),
                      y: (Double(Self.parent.y) + 0.5) / Double(1 << Self.parent.z))
        let latitude = atan(sinh(Double.pi * (1 - 2 * centre.y))) * 180 / .pi
        let longitude = centre.x * 360 - 180
        func look(zoom: Double) {
            harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                                  longitudeDegrees: longitude,
                                                                  zoom: zoom,
                                                                  bearing: 0,
                                                                  pitch: 0))
        }
        var frameIndex = 0
        func frames(_ count: Int, counting: (RenderedFrame.Pixel) -> Bool) async throws -> [Int] {
            var counts: [Int] = []
            for _ in 0 ..< count {
                let frame = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(frameIndex))
                frameIndex += 1
                counts.append(frame.count(where: counting))
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return counts
        }

        // Below the relief's zoom: the zoom 9 tiles are the targets, drawn
        // as geometry.
        look(zoom: 9.6)
        let roadsBefore = try await frames(8, counting: Self.isRoad).last ?? 0
        XCTAssertGreaterThan(roadsBefore, 500, "The roads show on the zoom 9 tiles")

        // Onto the relief, the zoom 10 tiles not in: the zoom 9 tiles
        // stand in for them. What stood on the ground stands on as it was
        // shown, so the roads stay until the zoom 10 tiles land.
        look(zoom: 10.3)
        let crossing = try await frames(40, counting: Self.isRoad)
        XCTAssertGreaterThan(crossing.min() ?? 0, roadsBefore / 4,
                             "A stand-in keeps its roads on the relief: \(crossing) road pixels against \(roadsBefore) before")

        // The zoom 10 tiles land, with their terrain: the ground changes
        // to its own tiles, residential, and the park goes.
        let residential = VectorTileFixture.fullCoverageTile(layerName: "landuse", properties: ["kind": "residential"])
        for dx in -3 ... 3 {
            for dy in -3 ... 3 {
                let tile = Tile(x: Self.parent.x * 2 + 1 + dx, y: Self.parent.y * 2 + 1 + dy, z: 10)
                let loaded = await harness.tileRenderStore.parseTile(tile: tile, data: residential)
                XCTAssertTrue(loaded, "The fixture tile must parse")
            }
        }
        let landed = try await frames(40, counting: Self.isPark)
        XCTAssertEqual(landed.last, 0, "The zoom 10 tiles take their slots: \(landed) park pixels")
    }

    /// The terrain lands after the map tiles, the camera still: the
    /// placements are planned over it and the slots' own tiles take their
    /// ground. The terrain comes from a loopback host that is down (503)
    /// until the frame has asked for it, so the tiles land on the store's
    /// retry, at the earliest after `retryBaseDelay`. (A host without the
    /// tile, a 404, is another case: the tile counts as flat at once.)
    @MainActor
    func testTheTerrainLandingAfterTheTilesPlacesThemWithTheCameraStill() async throws {
        var scene = try await makeSceneOverADownTerrainHost()
        // The host comes up. The camera does not move.
        scene.serves.withLock { $0 = true }
        let parkNow = try await scene.framesUntilTheParkGoes(within: GroundReliefStore.retryBaseDelay + 10)
        XCTAssertEqual(parkNow, 0, "The zoom 10 tiles take their slots once their terrain lands")
    }

    /// A terrain host that stays down: once its loads have failed
    /// `GroundReliefStore.unavailableAfterAttempts` times, the tiles over
    /// it are placed flat, on the plane, instead of waiting for ever.
    @MainActor
    func testATerrainHostThatStaysDownLeavesTheTilesOnThePlane() async throws {
        var scene = try await makeSceneOverADownTerrainHost()
        let parkNow = try await scene.framesUntilTheParkGoes(within: GroundReliefStore.retryBaseDelay + 10)
        XCTAssertEqual(parkNow, 0, "The zoom 10 tiles are placed flat once the host is known to be down")
    }

    /// The scene both host tests start from: the zoom 9 park tiles shown
    /// below the relief, then the camera on the relief at zoom 10.3 over
    /// the zoom 10 residential tiles, which are in but wait for their
    /// terrain from a host that answers 503 while `serves` is false. The
    /// zoom 9 tiles stand in meanwhile, as they were shown.
    @MainActor
    private struct DownHostScene {
        let harness: OffscreenFrameHarness
        let server: LocalTileServer
        let serves: Locked<Bool>
        var frameIndex: Int

        /// Renders until no park pixel is left, or `seconds` have passed,
        /// and returns the last count.
        mutating func framesUntilTheParkGoes(within seconds: TimeInterval) async throws -> Int {
            let deadline = Date().addingTimeInterval(seconds)
            var park = Int.max
            while park > 0, Date() < deadline {
                let frame = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(frameIndex))
                frameIndex += 1
                park = frame.count(where: GroundReliefStandInOffscreenTests.isPark)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return park
        }
    }

    @MainActor
    private func makeSceneOverADownTerrainHost() async throws -> DownHostScene {
        let serves = Locked(false)
        let png = try Self.flatPNG(size: 16)
        let server = try LocalTileServer { request in
            guard request.path.hasSuffix(".png") else { return nil }
            return serves.withLock { $0 } ? LocalTileServer.Resource(body: png, etag: "\"terrain\"", contentType: "image/png")
                : .unavailable
        }
        let base = try XCTUnwrap(server.baseURL, "The loopback host is up")
        var settings = ImmersiveMapSettings.default
            .mapStyle(ProtomapsBasemapMapStyle.default.apply { theme in
                theme.hillshade = .none
            })
        settings.camera.maximumZoom = 22
        settings.scene.starfield.starCount = 0
        settings.scene.shadows.isEnabled = false
        settings.scene.fog.isEnabled = false
        settings.labels.isEnabled = false
        settings = settings.groundRelief(isEnabled: true,
                                         tileURLTemplate: base.absoluteString + "/{z}/{x}/{y}.png",
                                         exaggeration: 1,
                                         collapseZoom: 30)
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings, size: 768)
        let park = VectorTileFixture.fullCoverageTile(layerName: "landuse", properties: ["kind": "park"])
        let residential = VectorTileFixture.fullCoverageTile(layerName: "landuse", properties: ["kind": "residential"])
        for dx in -1 ... 1 {
            for dy in -1 ... 1 {
                let tile = Tile(x: Self.parent.x + dx, y: Self.parent.y + dy, z: Self.parent.z)
                let loaded = await harness.tileRenderStore.parseTile(tile: tile, data: park)
                XCTAssertTrue(loaded, "The fixture tile must parse")
            }
        }
        let centre = (x: (Double(Self.parent.x) + 0.5) / Double(1 << Self.parent.z),
                      y: (Double(Self.parent.y) + 0.5) / Double(1 << Self.parent.z))
        func look(zoom: Double) {
            harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: atan(sinh(Double.pi * (1 - 2 * centre.y))) * 180 / .pi,
                                                                  longitudeDegrees: centre.x * 360 - 180,
                                                                  zoom: zoom,
                                                                  bearing: 0,
                                                                  pitch: 0))
        }
        var frameIndex = 0
        func frames(_ count: Int) async throws -> Int {
            var park = 0
            for _ in 0 ..< count {
                let frame = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(frameIndex))
                frameIndex += 1
                park = frame.count(where: Self.isPark)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return park
        }
        // Below the relief the zoom 9 park tiles are the targets.
        look(zoom: 9.6)
        let parkBelow = try await frames(8)
        XCTAssertGreaterThan(parkBelow, 100_000, "The zoom 9 tiles show below the relief")
        // The zoom 10 tiles land before the first frame on the relief asks
        // for them, so that frame finds them in and keeps them. Their
        // terrain is not in: the zoom 9 park stands in, as it was shown.
        // (Landed after that frame, the parse of the tiles would run past
        // the terrain's first retry, and a host down for two attempts
        // places the tiles flat, which is the other test's case.)
        for dx in -3 ... 3 {
            for dy in -3 ... 3 {
                let tile = Tile(x: Self.parent.x * 2 + 1 + dx, y: Self.parent.y * 2 + 1 + dy, z: 10)
                let loaded = await harness.tileRenderStore.parseTile(tile: tile, data: residential)
                XCTAssertTrue(loaded, "The fixture tile must parse")
            }
        }
        look(zoom: 10.3)
        let parkOverTheTiles = try await frames(8)
        XCTAssertGreaterThan(parkOverTheTiles, 100_000, "The zoom 9 tiles stand in while the terrain is out")
        return DownHostScene(harness: harness, server: server, serves: serves, frameIndex: frameIndex)
    }

    /// A magenta no fill of the fixture map has: the road's.
    private static let roadColour = SIMD4<Float>(1, 0, 1, 1)

    private static func isRoad(_ pixel: RenderedFrame.Pixel) -> Bool {
        Int(pixel.red) > Int(pixel.green) + 60 && Int(pixel.blue) > Int(pixel.green) + 60
    }

    /// The park's green, which the residential ground is not.
    private static func isPark(_ pixel: RenderedFrame.Pixel) -> Bool {
        Int(pixel.green) > Int(pixel.red) + 20 && Int(pixel.green) > Int(pixel.blue) + 20
    }

    /// Terrarium tiles `{z}/{x}/{y}.png` of level ground at 0 m, for every
    /// zoom a ring or the camera may read the terrain at, 3 to 10, over
    /// the zoom 10 tiles around the point looked at.
    private func makeFlatTerrainDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroundReliefStandInOffscreenTests-\(UUID().uuidString)", isDirectory: true)
        try writeFlatTerrain(into: root)
        return root
    }

    private func writeFlatTerrain(into root: URL) throws {
        let png = try Self.flatPNG(size: 16)
        var written = Set<Tile>()
        for dx in -4 ... 4 {
            for dy in -4 ... 4 {
                let fine = Tile(x: Self.parent.x * 2 + 1 + dx, y: Self.parent.y * 2 + 1 + dy, z: 10)
                for zoom in 3 ... 10 {
                    guard let tile = fine.findParentTile(atZoom: zoom), written.insert(tile).inserted else { continue }
                    let directory = root.appendingPathComponent("\(tile.z)/\(tile.x)", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try png.write(to: directory.appendingPathComponent("\(tile.y).png"))
                }
            }
        }
    }

    private static func flatPNG(size: Int) throws -> Data {
        let encoded = 32768
        let pixel: [UInt8] = [UInt8(encoded >> 8), UInt8(encoded & 0xFF), 0, 255]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(size * size * 4)
        for _ in 0 ..< size * size {
            bytes += pixel
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: size,
                                          height: size,
                                          bitsPerComponent: 8,
                                          bitsPerPixel: 32,
                                          bytesPerRow: size * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                          provider: provider,
                                          decode: nil,
                                          shouldInterpolate: false,
                                          intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

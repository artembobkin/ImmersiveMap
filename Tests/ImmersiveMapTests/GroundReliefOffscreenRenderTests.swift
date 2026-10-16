// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import ImageIO
@testable import ImmersiveMap
import UniformTypeIdentifiers
import XCTest

/// The flattened ground raised by its terrain, drawn: a park tile whose
/// terrain stands high among neighbours on the ground comes nearer a camera
/// looking straight down at a neighbour, so it covers more of the frame
/// than it does flat, and so it does when the camera looks at it: the
/// relief is drawn from under the point looked at and the camera's pose
/// holds (`GroundReliefCameraLift`), so the raised park comes as near as a
/// camera high over it sees it. The
/// terrain tiles are files, so no network is asked. Requires the compiled Metal library, so it skips
/// under `swift test` and runs in the xcodebuild workspace suite.
final class GroundReliefOffscreenRenderTests: XCTestCase {
    private static let tile = Tile(x: 9651, y: 12319, z: 15)

    @MainActor
    func testATileRaisedAboveTheGroundLookedAtComesNearer() async throws {
        let terrain = try makeTerrainDirectory(raisedMetres: 150)
        defer { try? FileManager.default.removeItem(at: terrain) }
        let neighbour = Tile(x: Self.tile.x + 1, y: Self.tile.y, z: Self.tile.z)

        // The camera stands far up at this zoom: a tall hill, so its rise
        // shows against the frame.
        let flat = try await parkPixels(relief: nil, lookingAt: neighbour, exaggeration: 20)
        let raised = try await parkPixels(relief: terrain, lookingAt: neighbour, exaggeration: 20)
        XCTAssertGreaterThan(flat, 0, "The park tile shows")
        XCTAssertGreaterThan(Double(raised), Double(flat) * 1.2,
                             "The raised park covers more of the frame: \(raised) pixels against \(flat) flat")
    }

    /// The camera looks at a point on the relief: the raised park it looks
    /// at lies at the origin, as far from the eye as the flat park, so its
    /// plateau covers the frame as the flat tile's middle does. The park's
    /// slopes, its outer eighths, fall away under the camera and show no
    /// green from straight above: the plateau is the terrain's inner ten
    /// sixteenths of the tile, read at the ring's zoom, and the frame
    /// holds that square of the flat tile's.
    @MainActor
    func testTheCameraLooksAtAPointOnTheRaisedPark() async throws {
        let terrain = try makeTerrainDirectory(raisedMetres: 150)
        defer { try? FileManager.default.removeItem(at: terrain) }

        let flat = try await parkPixels(relief: nil, lookingAt: Self.tile, exaggeration: 20)
        let raised = try await parkPixels(relief: terrain, lookingAt: Self.tile, exaggeration: 20)
        XCTAssertGreaterThan(flat, 0, "The park tile shows")
        let plateau = Double(flat) * pow(10.0 / 16.0, 2)
        XCTAssertEqual(Double(raised), plateau, accuracy: plateau * 0.2,
                       "The plateau at the flat park's distance: \(raised) pixels against \(flat) flat")
    }

    /// A road across the raised park rises with it: looked at from above
    /// it still crosses the middle of the frame, where a road left on the
    /// plane would lie under the raised ground.
    @MainActor
    func testARoadAcrossARaisedTileRisesWithIt() async throws {
        let terrain = try makeTerrainDirectory(raisedMetres: 150)
        defer { try? FileManager.default.removeItem(at: terrain) }

        let flat = try await parkPixels(relief: nil, lookingAt: Self.tile, road: true, counting: Self.isRoad)
        let raised = try await parkPixels(relief: terrain, lookingAt: Self.tile, road: true, counting: Self.isRoad)
        XCTAssertGreaterThan(flat, 100, "The road shows on the flat park")
        XCTAssertGreaterThan(Double(raised), Double(flat) * 0.7,
                             "The road rises with the park: \(raised) road pixels against \(flat) flat")
    }

    /// A building on the raised park rises with it, whole: looked at from
    /// above at the tiles' own zoom, from over the flat ground just past
    /// the park's east edge so the camera is not raised with it, its roof
    /// comes nearer and covers more of the frame than it does flat.
    @MainActor
    func testABuildingOnARaisedTileRisesWithIt() async throws {
        let terrain = try makeTerrainDirectory(raisedMetres: 150)
        defer { try? FileManager.default.removeItem(at: terrain) }
        let eastEdge: [(Int32, Int32)] = [(2900, 1536), (3900, 1536), (3900, 2560), (2900, 2560)]
        let justEast = SIMD2<Double>(0.55, 0)

        let flat = try await parkPixels(relief: nil, lookingAt: Self.tile, lookAtOffsetTiles: justEast,
                                        building: true, buildingRing: eastEdge, zoom: 15.5, counting: Self.isBuilding)
        let raised = try await parkPixels(relief: terrain, lookingAt: Self.tile, lookAtOffsetTiles: justEast,
                                          building: true, buildingRing: eastEdge, zoom: 15.5, exaggeration: 4,
                                          counting: Self.isBuilding)
        XCTAssertGreaterThan(flat, 1000, "The building shows on the flat park")
        XCTAssertGreaterThan(Double(raised), Double(flat) * 1.2,
                             "The building rises with the park and comes nearer: \(raised) pixels against \(flat) flat")
    }

    /// The raised ground hides what stands behind it: a building on the
    /// tile beyond a hill, in view over the flat park, is gone once the
    /// park rises into a hill between the camera and it. The ground writes
    /// its real depth over a relief.
    @MainActor
    func testAHillHidesTheBuildingBehindIt() async throws {
        let terrain = try makeTerrainDirectory(raisedMetres: 150)
        defer { try? FileManager.default.removeItem(at: terrain) }
        let beyond = Tile(x: Self.tile.x, y: Self.tile.y - 1, z: Self.tile.z)

        let flat = try await parkPixels(relief: nil, lookingAt: Self.tile, building: true, buildingTile: beyond,
                                        zoom: 15.3, pitch: 80 * .pi / 180, counting: Self.isBuilding)
        let behindTheHill = try await parkPixels(relief: terrain, lookingAt: Self.tile, building: true, buildingTile: beyond,
                                                 zoom: 15.3, pitch: 80 * .pi / 180, exaggeration: 8,
                                                 counting: Self.isBuilding)
        XCTAssertGreaterThan(flat, 2000, "The building beyond the flat park is in view")
        XCTAssertLessThan(Double(behindTheHill), Double(flat) * 0.05,
                          "The hill hides the building: \(behindTheHill) pixels against \(flat) over the flat park")
    }

    /// A building's lift is made once per tile and kept: a camera that
    /// zooms out afterwards sees the building where a fresh camera there
    /// does, not raised by the world units of the deeper zoom.
    @MainActor
    func testABuildingsLiftHoldsAcrossTheZooms() async throws {
        let terrain = try makeTerrainDirectory(raisedMetres: 150)
        defer { try? FileManager.default.removeItem(at: terrain) }

        let fresh = try await parkPixels(relief: terrain, lookingAt: Self.tile, building: true, zoom: 15.2,
                                         exaggeration: 1, counting: Self.isBuilding)
        let zoomedOut = try await parkPixels(relief: terrain, lookingAt: Self.tile, building: true, zoom: 15.2,
                                             exaggeration: 1, afterZoom: 17.5, counting: Self.isBuilding)
        XCTAssertGreaterThan(fresh, 1000, "The building shows")
        XCTAssertEqual(Double(zoomedOut), Double(fresh), accuracy: Double(fresh) * 0.05,
                       "The lift holds after a zoom out: \(zoomedOut) pixels against \(fresh) fresh")
    }

    /// The pixels of the frame in the park's green, or whatever `counting`
    /// picks, once the terrain is in, the camera looking straight down at
    /// the centre of `lookAt` from `zoom`. With `road`, a primary road
    /// crosses the park in the fixture's road colour; with `building`, a
    /// building stands on it in the fixture's building colour. With
    /// `afterZoom`, the camera first draws a few frames from that zoom.
    @MainActor
    private func parkPixels(relief terrain: URL?,
                            lookingAt lookAt: Tile,
                            lookAtOffsetTiles: SIMD2<Double> = .zero,
                            road: Bool = false,
                            building: Bool = false,
                            buildingTile: Tile? = nil,
                            buildingRing: [(Int32, Int32)] = [(1536, 1536), (2560, 1536), (2560, 2560), (1536, 2560)],
                            zoom: Double = 13,
                            pitch: Float = 0,
                            exaggeration: Float = 4,
                            afterZoom: Double? = nil,
                            counting: (RenderedFrame.Pixel) -> Bool = GroundReliefOffscreenRenderTests.isPark) async throws -> Int {
        var settings = ImmersiveMapSettings.default
            .mapStyle(ProtomapsBasemapMapStyle.default.apply { theme in
                theme.layers.roads.primary = Self.roadColour
                theme.layers.roads.casing = Self.roadColour
                theme.features.buildingFillColor = Self.buildingColour
                // The geometry alone: the slopes' shading would tint the
                // park's colour the pixels are told by.
                theme.hillshade = .none
            })
        settings.camera.maximumZoom = 22
        settings.scene.starfield.starCount = 0
        settings.scene.shadows.isEnabled = false
        settings.scene.fog.isEnabled = false
        settings.labels.isEnabled = false
        if let terrain {
            // The relief at every zoom: the collapse would draw the street
            // zooms on the plane. Every height, so each ring reads the
            // terrain of its own zoom, which the fixture serves.
            settings = settings.groundRelief(isEnabled: true,
                                             tileURLTemplate: terrain.absoluteString + "{z}/{x}/{y}.png",
                                             exaggeration: exaggeration,
                                             collapseZoom: 30,
                                             detail: .maximum)
        }
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings, size: 768)
        var layers: [(layerName: String, features: [VectorTileFixture.Feature])] = [
            (layerName: "landuse", features: [VectorTileFixture.Feature(id: 1,
                                                                        geometry: .polygon(ring: [(0, 0), (4096, 0), (4096, 4096), (0, 4096)]),
                                                                        properties: ["kind": "park"])])
        ]
        if road {
            layers.append((layerName: "roads", features: [VectorTileFixture.Feature(id: 2,
                                                                                    geometry: .line(points: [(0, 2048), (4096, 2048)]),
                                                                                    properties: ProtomapsRoadSpelling.properties(forClass: "primary"))]))
        }
        let buildingLayer: (layerName: String, features: [VectorTileFixture.Feature]) =
            (layerName: "buildings", features: [.building(id: 3,
                                                          ring: buildingRing,
                                                          height: buildingTile == nil ? "50" : "300")])
        if building, buildingTile == nil {
            layers.append(buildingLayer)
        }
        let park = VectorTileFixture.layersTile(layers)
        let residential = VectorTileFixture.fullCoverageTile(layerName: "landuse", properties: ["kind": "residential"])
        let residentialWithBuilding = VectorTileFixture.layersTile([
            (layerName: "landuse", features: [VectorTileFixture.Feature(id: 1,
                                                                        geometry: .polygon(ring: [(0, 0), (4096, 0), (4096, 4096), (0, 4096)]),
                                                                        properties: ["kind": "residential"])]),
            buildingLayer
        ])
        for dx in -3 ... 3 {
            for dy in -3 ... 3 {
                let neighbour = Tile(x: Self.tile.x + dx, y: Self.tile.y + dy, z: Self.tile.z)
                let data = dx == 0 && dy == 0 ? park : (building && neighbour == buildingTile ? residentialWithBuilding : residential)
                let loaded = await harness.tileRenderStore.parseTile(tile: neighbour, data: data)
                XCTAssertTrue(loaded, "The fixture tile must parse")
            }
        }
        // Far enough for the park to be a block in the frame: the coarser
        // tiles the camera's zoom asks for are not loaded, so the z15
        // tiles, the flattened ones, stand in for them.
        let centre = (x: (Double(lookAt.x) + 0.5 + lookAtOffsetTiles.x) / Double(1 << lookAt.z),
                      y: (Double(lookAt.y) + 0.5 + lookAtOffsetTiles.y) / Double(1 << lookAt.z))
        let latitude = atan(sinh(Double.pi * (1 - 2 * centre.y))) * 180 / .pi
        let longitude = centre.x * 360 - 180
        var frameIndex = 0
        if let afterZoom {
            harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                                  longitudeDegrees: longitude,
                                                                  zoom: afterZoom,
                                                                  bearing: 0,
                                                                  pitch: 0))
            while frameIndex < 40 {
                _ = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(frameIndex))
                frameIndex += 1
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                              longitudeDegrees: longitude,
                                                              zoom: zoom,
                                                              bearing: 0,
                                                              pitch: pitch))
        var count = 0
        // The terrain loads off the main thread: a few frames until it is in.
        for frameIndex in frameIndex ..< frameIndex + 40 {
            let frame = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(frameIndex))
            count = frame.count(where: counting)
            if terrain == nil, frameIndex >= 2 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return count
    }

    /// The park's green, which the residential ground and the land around
    /// it are not.
    private static func isPark(_ pixel: RenderedFrame.Pixel) -> Bool {
        Int(pixel.green) > Int(pixel.red) + 20 && Int(pixel.green) > Int(pixel.blue) + 20
    }

    /// A magenta no fill of the fixture map has: the road's.
    private static let roadColour = SIMD4<Float>(1, 0, 1, 1)
    /// A cyan no fill of the fixture map has: the building's, shaded by
    /// its lighting but never toward red.
    private static let buildingColour = SIMD4<Float>(0, 1, 1, 1)

    private static func isBuilding(_ pixel: RenderedFrame.Pixel) -> Bool {
        Int(pixel.green) > Int(pixel.red) + 60 && Int(pixel.blue) > Int(pixel.red) + 60
    }

    private static func isRoad(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 180 && pixel.green < 80 && pixel.blue > 180
    }

    /// A directory of Terrarium tiles `{z}/{x}/{y}.png`: the park tile a
    /// plateau at `raisedMetres` falling to sea level at its edge, so the
    /// hill is continuous with its neighbours at sea level and has slopes
    /// to see it by.
    /// The terrain over the fixture tiles at every zoom a ring may read
    /// it at, 12 to 15 (`GroundReliefStore.terrainZoom(forTargetZoom:)`):
    /// the park's tile a plateau of `raisedMetres`, its outermost
    /// eighth at the plain's height so it meets its neighbours, the rest
    /// at 0. A coarser zoom's tile is drawn larger, 8 pixels to a zoom
    /// 15 tile, so the plateau is the same ground at every zoom.
    private func makeTerrainDirectory(raisedMetres: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroundReliefOffscreenRenderTests-\(UUID().uuidString)", isDirectory: true)
        for zoom in 12 ... Self.tile.z {
            let span = 1 << (Self.tile.z - zoom)
            let size = 8 * span
            var written = Set<Tile>()
            for dx in -3 ... 3 {
                for dy in -3 ... 3 {
                    let fine = Tile(x: Self.tile.x + dx, y: Self.tile.y + dy, z: Self.tile.z)
                    guard let tile = fine.findParentTile(atZoom: zoom), written.insert(tile).inserted else { continue }
                    // The park's tile's block of 8 by 8 pixels in this tile.
                    let block = (x: (Self.tile.x - tile.x * span) * 8, y: (Self.tile.y - tile.y * span) * 8)
                    let directory = root.appendingPathComponent("\(tile.z)/\(tile.x)", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Self.png(size: size, raisedMetres: raisedMetres, block: block)
                        .write(to: directory.appendingPathComponent("\(tile.y).png"))
                }
            }
        }
        return root
    }

    /// A terrain tile of `size` pixels a side at 0 m, with the 8 by 8
    /// block at `block` at `raisedMetres` but for its outermost pixels.
    private static func png(size: Int, raisedMetres: Int, block: (x: Int, y: Int)) throws -> Data {
        func pixel(_ metres: Int) -> [UInt8] {
            let encoded = metres + 32768
            return [UInt8(encoded >> 8), UInt8(encoded & 0xFF), 0, 255]
        }
        var bytes: [UInt8] = []
        for row in 0 ..< size {
            for column in 0 ..< size {
                let inBlock = column > block.x && column < block.x + 7 && row > block.y && row < block.y + 7
                bytes += pixel(inBlock ? raisedMetres : 0)
            }
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

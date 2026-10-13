// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import ImageIO
@testable import ImmersiveMap
import Metal
import simd
import UniformTypeIdentifiers
import XCTest

/// The flattened ground raised by a heightmap: the Terrarium decoding, where
/// a ground tile lies in the terrain tile over it, and the store falling
/// back to an ancestor where the source has no terrain that deep.
final class GroundReliefTests: XCTestCase {
    func testTheTerrariumEncodingReadsMetres() {
        XCTAssertEqual(GroundReliefDecoder.height(red: 128, green: 0, blue: 0), 0)
        XCTAssertEqual(GroundReliefDecoder.height(red: 128, green: 100, blue: 128), 100.5)
        XCTAssertEqual(GroundReliefDecoder.height(red: 127, green: 255, blue: 0), -1)
        // Mapbox: (red * 65536 + green * 256 + blue) / 10 - 10000.
        XCTAssertEqual(GroundReliefDecoder.height(red: 1, green: 134, blue: 160, encoding: .mapbox), 0)
        XCTAssertEqual(GroundReliefDecoder.height(red: 1, green: 134, blue: 170, encoding: .mapbox), 1)
        XCTAssertEqual(GroundReliefDecoder.height(red: 0, green: 0, blue: 0, encoding: .mapbox), -10000)
    }

    /// A PNG decodes to its heights row by row from the north edge, its
    /// bytes untouched by any colour conversion.
    func testATerrainImageDecodesToItsHeights() throws {
        let pixels: [(UInt8, UInt8, UInt8)] = [(128, 0, 0), (128, 100, 128),
                                               (127, 255, 0), (130, 16, 64)]
        let decoded = try GroundReliefDecoder.decode(Self.png(size: 2, pixels: pixels))
        XCTAssertEqual(decoded.size, 2)
        XCTAssertEqual(decoded.metres, [0, 100.5, -1, 528.25])
    }

    func testABorderedTileDecodesItsPlateauAndItsEdge() throws {
        var pixels: [(UInt8, UInt8, UInt8)] = []
        for row in 0 ..< 8 {
            for column in 0 ..< 8 {
                let atEdge = row == 0 || row == 7 || column == 0 || column == 7
                pixels.append(atEdge ? (128, 0, 0) : (128, 150, 0))
            }
        }
        let decoded = try GroundReliefDecoder.decode(Self.png(size: 8, pixels: pixels))
        XCTAssertEqual(decoded.size, 8)
        XCTAssertEqual(decoded.metres[0], 0)
        XCTAssertEqual(decoded.metres[9], 150)
        XCTAssertEqual(decoded.metres[27], 150)
        XCTAssertEqual(decoded.metres[63], 0)
        XCTAssertEqual(decoded.metres.filter { $0 == 150 }.count, 36)
    }

    func testANonSquareImageIsRefused() throws {
        let data = try Self.png(width: 2, height: 1, pixels: [(128, 0, 0), (128, 0, 0)])
        XCTAssertThrowsError(try GroundReliefDecoder.decode(data)) { error in
            XCTAssertEqual(error as? GroundReliefDecoder.Failure, .notSquare(width: 2, height: 1))
        }
    }

    func testATileLiesInItsAncestorsTerrainByItsAddress() {
        let own = GroundRelief.placement(of: Tile(x: 9647, y: 12320, z: 15), in: Tile(x: 9647, y: 12320, z: 15))
        XCTAssertEqual(own.origin, SIMD2<Float>(0, 0))
        XCTAssertEqual(own.scale, 1)
        let ancestor = GroundRelief.placement(of: Tile(x: 9647, y: 12321, z: 15), in: Tile(x: 1205, y: 1540, z: 12))
        XCTAssertEqual(ancestor.origin, SIMD2<Float>(0.875, 0.125))
        XCTAssertEqual(ancestor.scale, 0.125)
    }

    func testTheURLTemplateTakesTheAddress() throws {
        let device = try Self.device()
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true,
                                                                              tileURLTemplate: "https://terrain.example/{z}/{x}/{y}.png")
        let store = GroundReliefStore(device: device, settings: settings, fetch: { _ in .missing })
        XCTAssertEqual(store.url(for: Tile(x: 3, y: 5, z: 4))?.absoluteString, "https://terrain.example/4/3/5.png")
    }

    /// The source has no terrain at zoom 15: the tile is flat until its
    /// parent's terrain arrives, and then lies in its quarter of it.
    func testATileWithoutTerrainOfItsOwnRisesByItsParents() throws {
        let device = try Self.device()
        let parentImage = try Self.png(size: 2, pixels: Array(repeating: (128, 10, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true,
                                                                              tileURLTemplate: "https://terrain.example/{z}/{x}/{y}.png",
                                                                              minimumSourceZoom: 12)
        let store = GroundReliefStore(device: device, settings: settings, fetch: { url in
            url.absoluteString.contains("/15/") ? .missing : .image(parentImage)
        })
        let tile = Tile(x: 9647, y: 12321, z: 15)

        XCTAssertNil(store.relief(for: tile, terrainZoom: tile.z), "Nothing is in before the first load")
        let relief = try XCTUnwrap(waitForRelief(of: tile, in: store))
        XCTAssertEqual(relief.scale, 0.5)
        XCTAssertEqual(relief.origin, SIMD2<Float>(0.5, 0.5))
        XCTAssertEqual(relief.texture.pixelFormat, .r16Float)
        XCTAssertEqual(relief.texture.width, 2)
    }

    /// The reference height is read back from the texture, bilinear between
    /// the texels around the point: here a west half at 0 m and an east
    /// half at 100 m, the point a quarter texel east of the middle.
    func testTheElevationUnderAPointIsReadBackBilinearly() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: [(128, 0, 0), (128, 100, 0), (128, 0, 0), (128, 100, 0)])
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true, minimumSourceZoom: 15)
        let store = GroundReliefStore(device: device, settings: settings, fetch: { _ in .image(image) })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: store))
        let tilesCount = Double(1 << 15)
        let point = SIMD2<Double>((Double(tile.x) + 0.625) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)
        let elevation = try XCTUnwrap(store.elevation(atNormalizedWorld: point, terrainZoom: 15))
        XCTAssertEqual(elevation, 75, accuracy: 0.01)
        XCTAssertNil(store.elevation(atNormalizedWorld: SIMD2(0.1, 0.1), terrainZoom: 15), "Terrain not in yet")
    }

    /// The terrain under the point the camera looks at is the frame's
    /// datum, which the relief is drawn from, in the terrain's own metres.
    func testTheTerrainUnderThePointLookedAtIsTheDatum() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 100, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true,
                                                                              exaggeration: 2,
                                                                              minimumSourceZoom: 15,
                                                                              cameraClearanceMetres: 30)
        let store = GroundReliefStore(device: device, settings: settings, fetch: { _ in .image(image) })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: store))
        let tilesCount = Double(1 << 15)
        let centre = SIMD2<Double>((Double(tile.x) + 0.5) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)
        let renderMapSize = 1_000_000.0
        let unitsPerMetre = Float(ImmersiveMapProjection.worldUnitsPerMeter(
            latitudeRadians: ImmersiveMapProjection.latitude(fromNormalizedWorldY: centre.y),
            renderMapSize: renderMapSize))
        let datum = try XCTUnwrap(GroundReliefCameraLift.datumMetres(store: store,
                                                                     centerWorldMercator: centre,
                                                                     tileZoom: 16))
        XCTAssertEqual(datum, 100, accuracy: 0.01, "The terrain's own metres, before the exaggeration")
        store.setDatum(metres: datum)
    }

    /// The centre of the screen meets the terrain as drawn from the datum:
    /// over a terrain 100 m high drawn twice as tall, from a datum of
    /// zero it meets the ground 200 m nearer than the plane, and that is
    /// the depth the road widths are stated at. From the terrain's own
    /// datum, the ground lies at the origin, and the depth is the plane's.
    func testTheCentreOfTheScreenMeetsTheTerrainNotThePlane() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 100, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true,
                                                                              exaggeration: 2,
                                                                              minimumSourceZoom: 15)
        let store = GroundReliefStore(device: device, settings: settings, fetch: { _ in .image(image) })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: store))
        let tilesCount = Double(1 << 15)
        let centre = SIMD2<Double>((Double(tile.x) + 0.5) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)
        let renderMapSize = 1_000_000.0
        let unitsPerMetre = Float(ImmersiveMapProjection.worldUnitsPerMeter(
            latitudeRadians: ImmersiveMapProjection.latitude(fromNormalizedWorldY: centre.y),
            renderMapSize: renderMapSize))
        // The camera 1000 m up, looking at the origin at a 60 degree pitch.
        let eye = SIMD3<Float>(0, -1000 * unitsPerMetre * tan(Float.pi / 3), 1000 * unitsPerMetre)
        let cameraMatrix = Matrix.perspectiveMatrix(fovRadians: 1, aspect: 1, near: 0.01, far: 100)
            * Matrix.lookAt(eye: eye, center: .zero, up: SIMD3<Float>(0, 0, 1))
        let planeDepth = FlatMapSurfaceDrawer.screenCentreGroundDepth(cameraMatrix: cameraMatrix)
        let depth = try XCTUnwrap(GroundReliefCameraLift.centreGroundDepth(store: store,
                                                                           cameraMatrix: cameraMatrix,
                                                                           centerWorldMercator: centre,
                                                                           tileZoom: 16,
                                                                           renderMapSize: renderMapSize))
        // Along a ray at 60 degrees from the vertical, 200 m of height are
        // 200 / cos(60) = 400 m of depth.
        XCTAssertEqual(depth, planeDepth - 400 * unitsPerMetre, accuracy: unitsPerMetre)
        store.setDatum(metres: 100)
        let fromTheDatum = try XCTUnwrap(GroundReliefCameraLift.centreGroundDepth(store: store,
                                                                                  cameraMatrix: cameraMatrix,
                                                                                  centerWorldMercator: centre,
                                                                                  tileZoom: 16,
                                                                                  renderMapSize: renderMapSize))
        XCTAssertEqual(fromTheDatum, planeDepth, accuracy: unitsPerMetre)
    }

    func testHalfFloatsReadBack() {
        // 1.0, -2.0 and 1000.0 as half floats.
        XCTAssertEqual(GroundReliefStore.floats(halfBits: [0x3C00, 0xC000, 0x63D0]), [1, -2, 1000])
    }

    /// A source with no terrain anywhere down to the minimum zoom leaves
    /// the tile flat, and stops asking.
    func testATileWithoutAnyTerrainStaysFlat() throws {
        let device = try Self.device()
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true, minimumSourceZoom: 14)
        let store = GroundReliefStore(device: device, settings: settings, fetch: { _ in .missing })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        for _ in 0 ..< 20 {
            _ = store.relief(for: tile, terrainZoom: tile.z)
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertNil(store.relief(for: tile, terrainZoom: tile.z))
    }

    func testTheReliefIsOffByDefault() {
        XCTAssertFalse(ImmersiveMapSettings.default.tiles.groundRelief.isEnabled)
        let settings = ImmersiveMapSettings.default.groundRelief(isEnabled: true, exaggeration: 3)
        XCTAssertTrue(settings.tiles.groundRelief.isEnabled)
        XCTAssertEqual(settings.tiles.groundRelief.exaggeration, 3)
        XCTAssertEqual(settings.tiles.groundRelief.tileURLTemplate,
                       ImmersiveMapSettings.TileSettings.GroundReliefSettings().tileURLTemplate,
                       "An omitted value is left as configured")
    }

    /// The relief's zoom pulls the flattening up to it: only a flattened
    /// tile can rise, so with the relief on from zoom 12 the tiles are
    /// flattened from 12, whatever the flattening's own zoom, and a deeper
    /// relief zoom leaves an earlier flattening as it is.
    /// With the relief on every tile is flattened, whatever the
    /// flattening's own zoom: a frame on the terrain raises the coarse
    /// tiles of its far rings too.
    func testTheReliefFlattensEveryZoom() {
        var settings = ImmersiveMapSettings.default
        XCTAssertEqual(settings.tiles.resolvedGroundFlatteningFromTileZoom, 15, "Off, the flattening's own zoom")
        settings = settings.groundRelief(isEnabled: true)
        XCTAssertEqual(settings.tiles.groundRelief.fromTileZoom, 0, "The ground rises from the plane's first frame")
        XCTAssertEqual(settings.tiles.resolvedGroundFlatteningFromTileZoom, 0)
        XCTAssertTrue(TileParseOptions(settings: settings).flattensGround(tileZoom: 12))
        XCTAssertTrue(TileParseOptions(settings: settings).flattensGround(tileZoom: 3))
        settings = settings.groundFlattening(isEnabled: false)
        XCTAssertEqual(settings.tiles.resolvedGroundFlatteningFromTileZoom, 0, "The relief flattens on its own")
        settings = settings.groundRelief(isEnabled: false)
        XCTAssertNil(settings.tiles.resolvedGroundFlatteningFromTileZoom)
    }

    /// A zoom may take a grid of its own, which is prepared-cache identity.
    func testAZoomMayTakeAGridOfItsOwn() {
        let settings = ImmersiveMapSettings.default.groundFlattening(grid: 32, gridByTileZoom: [12: 128, 13: 96])
        let options = TileParseOptions(settings: settings)
        XCTAssertEqual(options.groundFlatteningGrid(forTileZoom: 12), 128)
        XCTAssertEqual(options.groundFlatteningGrid(forTileZoom: 13), 96)
        XCTAssertEqual(options.groundFlatteningGrid(forTileZoom: 15), 32)
        XCTAssertEqual(options.groundFlatteningGridByTileZoomKey, "12=128,13=96")
        XCTAssertEqual(TileParseOptions(settings: .default).groundFlatteningGridByTileZoomKey, "")
        var relief = settings.groundRelief(isEnabled: true)
        XCTAssertEqual(TileParseOptions(settings: relief).reliefSubdivisionStep(tileZoom: 12), 32, "4096 over 128")
        relief.tiles.groundFlattening.gridByTileZoom[12] = 1000
        XCTAssertEqual(TileParseOptions(settings: relief).groundFlatteningGrid(forTileZoom: 12), 256, "Clamped like the grid")
    }

    /// The relief is the frame's: a frame on the terrain raises every
    /// tile it draws, the coarse ones of its far rings too, and a frame
    /// off it (one of tiles coarser than the relief's zoom) lies whole on
    /// the plane, with everything placed by the terrain: no relief for any
    /// tile, a height of zero under any point, a datum of zero and no lift
    /// for the camera.
    func testAFrameOffTheTerrainLiesOnThePlane() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 100, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true,
                                                                              fromTileZoom: 12,
                                                                              minimumSourceZoom: 10)
        let store = GroundReliefStore(device: device, settings: settings, fetch: { _ in .image(image) })
        let deep = Tile(x: 9647, y: 12321, z: 15)
        let coarse = Tile(x: 9647 >> 4, y: 12321 >> 4, z: 11)
        _ = try XCTUnwrap(waitForRelief(of: deep, in: store))
        _ = try XCTUnwrap(waitForRelief(of: coarse, in: store), "On the terrain a coarse far tile rises too")
        let tilesCount = Double(1 << 15)
        let centre = SIMD2<Double>((Double(deep.x) + 0.5) / tilesCount, (Double(deep.y) + 0.5) / tilesCount)
        XCTAssertEqual(store.elevation(atNormalizedWorld: centre, terrainZoom: 15), 100)
        store.setActive(false)
        XCTAssertNil(store.relief(for: deep, terrainZoom: deep.z), "Off the terrain every tile lies on the plane")
        XCTAssertNil(store.relief(for: coarse, terrainZoom: coarse.z))
        XCTAssertEqual(store.elevation(atNormalizedWorld: centre, terrainZoom: 15), 0, "The plane under a coarse frame")
        store.setActive(true)
        XCTAssertEqual(GroundReliefCameraLift.datumMetres(store: store,
                                                          centerWorldMercator: centre,
                                                          tileZoom: 11), 0,
                       "The relief over coarse tiles is drawn from the plane")
        XCTAssertEqual(GroundReliefCameraLift.datumMetres(store: store,
                                                          centerWorldMercator: centre,
                                                          tileZoom: 16), 100)
    }

    /// The camera's terrain as the engine makes it: over a slope a pan
    /// uphill through the controller keeps the eye's altitude by a deeper
    /// zoom, reading the terrain at the zoom of the frame's tiles, and
    /// below the relief's zoom it is the plane.
    func testAPanUphillThroughTheStoresTerrainKeepsTheEyesAltitude() throws {
        let device = try Self.device()
        // The west column at sea level, the east at 300 m: a slope the eye
        // at this zoom stands well over.
        let image = try Self.png(size: 2, pixels: [(128, 0, 0), (129, 44, 0), (128, 0, 0), (129, 44, 0)])
        var settings = ImmersiveMapSettings.default
        settings.camera.maximumZoom = 22
        // Tiles to zoom 16, whose ring reads the fixtures' zoom 15 terrain.
        settings.tiles.coverage.maximumZoomLevel = 16
        settings = settings.groundRelief(isEnabled: true, fromTileZoom: 12)
        settings.tiles.groundRelief.minimumSourceZoom = 15
        let store = GroundReliefStore(device: device, settings: settings.tiles.groundRelief, fetch: { _ in .image(image) })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: store))
        let tilesCount = Double(1 << 15)
        let west = SIMD2<Double>((Double(tile.x) + 0.3) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)
        let east = SIMD2<Double>((Double(tile.x) + 0.7) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)

        let controller = CameraStateController(settings: settings.camera)
        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: west, zoom: 16.5, bearing: 0, pitch: 0.5))
        let follow = store.makeTerrainFollow(tileSettings: settings.tiles,
                                             globeRadiusScale: settings.presentation.globeRadiusScale,
                                             cameraZoom: { controller.cameraState.zoom })
        controller.terrainFollow = follow
        let westMetres = try XCTUnwrap(follow.terrainMetres(west))
        let eastMetres = try XCTUnwrap(follow.terrainMetres(east))
        XCTAssertGreaterThan(eastMetres, westMetres + 200, "The slope rises eastward")
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: west.y)
        let altitudeBefore = Double(westMetres) + follow.eyeHeightMetres(zoom: 16.5, pitch: 0.5, latitude: latitude)

        let followed = controller.followTerrain(from: west, to: east, follow: follow)
        XCTAssertGreaterThan(followed.zoom, 16.5, "Uphill the arm shortens: a deeper zoom")
        let altitudeAfter = Double(try XCTUnwrap(follow.terrainMetres(followed.center)))
            + follow.eyeHeightMetres(zoom: followed.zoom, pitch: 0.5, latitude: latitude)
        XCTAssertEqual(altitudeAfter, altitudeBefore, accuracy: 1, "The eye keeps its altitude")

        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: west, zoom: 11.5, bearing: 0, pitch: 0.5))
        XCTAssertEqual(follow.terrainMetres(east), 0, "Below the relief's zoom the terrain is the plane")
    }

    /// A drag up a slope, as the gesture delivers it: many small pans
    /// through the controller's own pan, each keeping the eye's altitude,
    /// and each moving the eye over the map by the same step, the drag's
    /// speed being held at the zoom it started with. The slope rises along
    /// the view and is steeper than the view ray (about 35 degrees against
    /// a pitch of 63): the ray meets it short of where a flat pan would
    /// have put the point.
    func testADragUphillInSmallStepsKeepsTheEyesAltitude() throws {
        let device = try Self.device()
        // The north row at 300 m, the south at sea level: a slope rising
        // north. The tiles around it, where the eye stands, are flat.
        let image = try Self.png(size: 2, pixels: [(129, 44, 0), (129, 44, 0), (128, 0, 0), (128, 0, 0)])
        let flat = try Self.png(size: 2, pixels: Array(repeating: (128, 0, 0), count: 4))
        var settings = ImmersiveMapSettings.default
        settings.camera.maximumZoom = 22
        // Tiles to zoom 16, whose ring reads the fixtures' zoom 15 terrain.
        settings.tiles.coverage.maximumZoomLevel = 16
        settings = settings.groundRelief(isEnabled: true, fromTileZoom: 12)
        settings.tiles.groundRelief.minimumSourceZoom = 15
        let store = GroundReliefStore(device: device, settings: settings.tiles.groundRelief, fetch: { url in
            .image(url.path.hasSuffix("/9647/12321.webp") ? image : flat)
        })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: store))
        _ = try XCTUnwrap(waitForRelief(of: Tile(x: 9647, y: 12322, z: 15), in: store))
        let tilesCount = Double(1 << 15)
        let south = SIMD2<Double>((Double(tile.x) + 0.5) / tilesCount, (Double(tile.y) + 0.8) / tilesCount)

        let controller = CameraStateController(settings: settings.camera)
        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: south, zoom: 16.5, bearing: 0, pitch: 1.1))
        let follow = store.makeTerrainFollow(tileSettings: settings.tiles,
                                             globeRadiusScale: settings.presentation.globeRadiusScale,
                                             cameraZoom: { controller.cameraState.zoom })
        controller.terrainFollow = follow
        func altitude() throws -> Double {
            let state = controller.cameraState
            let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: state.centerWorldMercator.y)
            return Double(try XCTUnwrap(follow.terrainMetres(state.centerWorldMercator)))
                + follow.eyeHeightMetres(zoom: state.zoom, pitch: state.pitch, latitude: latitude)
        }
        let altitudeBefore = try altitude()
        var trace: [String] = []
        func eyeGround() -> SIMD2<Double> {
            let state = controller.cameraState
            let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: state.centerWorldMercator.y)
            return follow.eyeGround(center: state.centerWorldMercator, zoom: state.zoom, pitch: state.pitch,
                                    bearing: state.bearing, latitude: latitude)
        }
        var steps: [Double] = []
        for _ in 0 ..< 40 {
            let before = eyeGround()
            controller.pan(deltaX: 0, deltaY: 4, transition: 1)
            let state = controller.cameraState
            steps.append((before.y - eyeGround().y) * tilesCount)
            guard let terrain = follow.terrainMetres(state.centerWorldMercator) else {
                XCTFail("Off the terrain: \(trace.joined(separator: "\n"))")
                return
            }
            trace.append("y:\((state.centerWorldMercator.y - Double(tile.y) / tilesCount) * tilesCount) z:\(state.zoom) terrain:\(terrain) alt:\(try altitude())")
        }
        let state = controller.cameraState
        XCTAssertLessThan(state.centerWorldMercator.y, south.y - 0.2 / tilesCount, "The drag went north, uphill: \(trace)")
        let firstStep = try XCTUnwrap(steps.first)
        XCTAssertEqual(try XCTUnwrap(steps.last), firstStep, accuracy: firstStep * 0.02,
                       "The eye takes the same step over the map up the slope as at its foot: \(steps)")
        XCTAssertGreaterThan(state.zoom, 16.5, "Uphill the zoom deepens")
        XCTAssertEqual(try altitude(), altitudeBefore, accuracy: 1, "The eye keeps its altitude: \(trace.joined(separator: "\n"))")
    }

    /// The relief goes with the camera zoom: over flat ground full before
    /// the flat fade, flat past it, between them scaled down, and the
    /// camera's terrain with it.
    func testTheReliefFadesOutWithTheCameraZoom() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 100, 0), count: 4))
        var settings = ImmersiveMapSettings.default
        settings.tiles.coverage.maximumZoomLevel = 16
        settings = settings.groundRelief(isEnabled: true, fromTileZoom: 10, exaggeration: 2,
                                         flatZoomFade: .fadeOut(from: 14, to: 16), mountainZoomFade: .fadeOut(from: 17, to: 19))
        settings.tiles.groundRelief.minimumSourceZoom = 15
        let store = GroundReliefStore(device: device, settings: settings.tiles.groundRelief, fetch: { _ in .image(image) })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: store))
        let tilesCount = Double(1 << 15)
        let centre = SIMD2<Double>((Double(tile.x) + 0.5) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)
        // The camera's terrain is read at the camera's tile zoom, so the
        // camera stays over the fixture's zoom 15 tile while it fades.
        var cameraZoom = 16.0
        let follow = store.makeTerrainFollow(tileSettings: settings.tiles,
                                             globeRadiusScale: settings.presentation.globeRadiusScale,
                                             cameraZoom: { cameraZoom })
        func strength() throws -> Float {
            try XCTUnwrap(store.strength(atNormalizedWorld: centre, terrainZoom: 15))
        }
        XCTAssertEqual(try XCTUnwrap(store.mountainShare(atNormalizedWorld: centre, terrainZoom: 15)), 0, "Level ground")
        store.setFrame(cameraZoom: 13)
        XCTAssertEqual(try strength(), 2, "Full before the fade")
        store.setFrame(cameraZoom: 15)
        XCTAssertEqual(try strength(), 1, accuracy: 1e-6, "Halfway through the flat fade")
        XCTAssertEqual(try XCTUnwrap(follow.terrainMetres(centre)), 100, accuracy: 1e-3, "The camera's terrain scales with it")
        store.setFrame(cameraZoom: 17)
        cameraZoom = 17
        XCTAssertEqual(try strength(), 0, "Flat past the fade")
        XCTAssertEqual(try XCTUnwrap(follow.terrainMetres(centre)), 0)
        XCTAssertEqual(store.elevation(atNormalizedWorld: centre, terrainZoom: 15), 100, "The heights themselves are untouched")
        let everywhere = GroundReliefStore(device: device,
                                           settings: settings.groundRelief(flatZoomFade: ImmersiveMapZoomFade.none).tiles.groundRelief,
                                           fetch: { _ in .image(image) })
        _ = try XCTUnwrap(waitForRelief(of: tile, in: everywhere))
        everywhere.setFrame(cameraZoom: 20)
        XCTAssertEqual(try XCTUnwrap(everywhere.strength(atNormalizedWorld: centre, terrainZoom: 15)), 2,
                       "No fade keeps the relief at every zoom")
    }

    /// The relief comes in with the camera zoom: flat before its fade,
    /// scaled up through it, full past it, with the fades that take it
    /// away again on top. The camera's terrain follows, so below the fade
    /// the camera stands on the plane.
    func testTheReliefAppearsWithTheCameraZoom() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 100, 0), count: 4))
        var settings = ImmersiveMapSettings.default
        settings.tiles.coverage.maximumZoomLevel = 16
        settings = settings.groundRelief(isEnabled: true, exaggeration: 2,
                                         appearZoomFade: .fadeIn(from: 10, to: 11),
                                         flatZoomFade: .fadeOut(from: 14, to: 16), mountainZoomFade: .none)
        XCTAssertEqual(ImmersiveMapSettings.default.tiles.groundRelief.appearZoomFade, .fadeIn(from: 10, to: 11),
                       "Flat to zoom 10 and full from 11 by default")
        settings.tiles.groundRelief.minimumSourceZoom = 15
        let store = GroundReliefStore(device: device, settings: settings.tiles.groundRelief, fetch: { _ in .image(image) })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: store))
        let tilesCount = Double(1 << 15)
        let centre = SIMD2<Double>((Double(tile.x) + 0.5) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)
        let follow = store.makeTerrainFollow(tileSettings: settings.tiles,
                                             globeRadiusScale: settings.presentation.globeRadiusScale,
                                             cameraZoom: { 16 })
        func strength() throws -> Float {
            try XCTUnwrap(store.strength(atNormalizedWorld: centre, terrainZoom: 15))
        }
        store.setFrame(cameraZoom: 9.5)
        XCTAssertEqual(try strength(), 0, "Flat before the relief comes in")
        XCTAssertFalse(store.comesIn(atCameraZoom: 9.5), "And the frame is off the terrain there")
        XCTAssertTrue(store.comesIn(atCameraZoom: 10.5))
        XCTAssertTrue(store.comesIn(atCameraZoom: 16), "On it past the fade that scales the relief away: the terrain tells the fade")
        store.setFrame(cameraZoom: 10.5)
        XCTAssertEqual(try strength(), 1, accuracy: 1e-6, "Halfway in")
        XCTAssertEqual(try XCTUnwrap(follow.terrainMetres(centre)), 100, accuracy: 1e-3, "The camera's terrain rises with it")
        store.setFrame(cameraZoom: 12)
        XCTAssertEqual(try strength(), 2, "Full past the fade")
        store.setFrame(cameraZoom: 15)
        XCTAssertEqual(try strength(), 1, accuracy: 1e-6, "The flat fade takes it away again on top")
        let atOnce = GroundReliefStore(device: device,
                                       settings: settings.groundRelief(appearZoomFade: ImmersiveMapZoomFade.none).tiles.groundRelief,
                                       fetch: { _ in .image(image) })
        _ = try XCTUnwrap(waitForRelief(of: tile, in: atOnce))
        atOnce.setFrame(cameraZoom: 5)
        XCTAssertEqual(try XCTUnwrap(atOnce.strength(atNormalizedWorld: centre, terrainZoom: 15)), 2,
                       "No fade draws the relief from the plane's first frame")
    }

    /// Over a mountain the relief stays late: the terrain's rise and fall
    /// around the place is past the mountain threshold, so the mountain
    /// fade holds where the flat one would have gone. The share is the
    /// place's, read off the terrain (`GroundReliefRoughness`), not the
    /// frame's.
    func testOverAMountainTheReliefFadesLate() throws {
        let device = try Self.device()
        // The west column at sea level, the east at 1024 m.
        let image = try Self.png(size: 2, pixels: [(128, 0, 0), (132, 0, 0), (128, 0, 0), (132, 0, 0)])
        var settings = ImmersiveMapSettings.default
        settings = settings.groundRelief(isEnabled: true, fromTileZoom: 10, exaggeration: 1,
                                         flatZoomFade: .fadeOut(from: 13, to: 15), mountainZoomFade: .fadeOut(from: 16, to: 18),
                                         reliefWindowMetres: 800, flatReliefMetres: 100, mountainReliefMetres: 500)
        settings.tiles.groundRelief.minimumSourceZoom = 15
        let store = GroundReliefStore(device: device, settings: settings.tiles.groundRelief, fetch: { _ in .image(image) })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: store))
        let tilesCount = Double(1 << 15)
        let centre = SIMD2<Double>((Double(tile.x) + 0.5) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)
        XCTAssertEqual(try XCTUnwrap(store.mountainShare(atNormalizedWorld: centre, terrainZoom: 15)), 1,
                       "A mountain's rise within the window")
        store.setFrame(cameraZoom: 16)
        XCTAssertEqual(try XCTUnwrap(store.strength(atNormalizedWorld: centre, terrainZoom: 15)), 1,
                       "Full at a zoom the flat fade would have ended at")
        store.setFrame(cameraZoom: 17)
        XCTAssertEqual(try XCTUnwrap(store.strength(atNormalizedWorld: centre, terrainZoom: 15)), 0.5, accuracy: 1e-6,
                       "Halfway through the mountain fade")
        // Off the terrain everything lies on the plane.
        store.setActive(false)
        XCTAssertEqual(store.strength(atNormalizedWorld: centre, terrainZoom: 15), 0)
    }

    /// The roughness of a tile: a cell's share is the rise and fall within
    /// the window of it, a plain reads as flat and a mountain as one, with
    /// a smoothstep between, and the window reaches across the tile only
    /// as far as it is wide.
    func testTheRoughnessReadsEachPlacesRise() throws {
        let device = try Self.device()
        // A 4 by 4 tile: the west half at sea level, the east half 1000 m
        // up, read in a window a cell wide at zoom 8, where a cell is tens
        // of kilometres.
        var metres = [Float](repeating: 0, count: 16)
        for row in 0 ..< 4 {
            for column in 2 ..< 4 {
                metres[row * 4 + column] = 1000
            }
        }
        let heights = GroundReliefHeights(size: 4, metres: metres)
        let tile = Tile(x: 132, y: 91, z: 8)
        let roughness = try XCTUnwrap(GroundReliefRoughness.make(heights: heights, tile: tile,
                                                                 windowMetres: 1, flatMetres: 100, mountainMetres: 1000,
                                                                 device: device))
        XCTAssertEqual(roughness.cells, 4)
        XCTAssertEqual(roughness.shares[0], 0, "A plain far from the step, the window a cell wide")
        XCTAssertEqual(roughness.shares[3], 0, "The plateau too: level ground")
        XCTAssertEqual(roughness.shares[1], 1, accuracy: 1e-6, "A cell beside the step sees the whole rise")
        XCTAssertEqual(roughness.shares[2], 1, accuracy: 1e-6)
        let wide = try XCTUnwrap(GroundReliefRoughness.make(heights: heights, tile: tile,
                                                            windowMetres: 1_000_000, flatMetres: 100, mountainMetres: 1000,
                                                            device: device))
        XCTAssertEqual(wide.shares[0], 1, accuracy: 1e-6, "A window over the whole tile reads the step everywhere")
        XCTAssertEqual(roughness.share(atTextureUV: SIMD2<Float>(0.125, 0.5)), 0, accuracy: 1e-6, "The first cell's centre")
        XCTAssertEqual(roughness.share(atTextureUV: SIMD2<Float>(0.25, 0.5)), 0.5, accuracy: 1e-6, "Halfway to the next")
    }

    /// Between flat ground and mountains the relief goes at a zoom
    /// between the two fades' zooms, and whole: the fades' zooms are
    /// blended by the share of a mountain, not their alphas, which would
    /// have left a part of the relief standing to the mountain fade. A
    /// fade of `.none` stands at an infinite zoom: the relief stays
    /// wherever that fade has any share.
    func testFoothillsFadeBetweenTheTwoFadesAndWhole() {
        let flat = ImmersiveMapZoomFade.fadeOut(from: 10, to: 12)
        let mountain = ImmersiveMapZoomFade.fadeOut(from: 17, to: 18)
        func alpha(_ zoom: Double, share: Float, flat: ImmersiveMapZoomFade = flat) -> Float {
            GroundReliefFrame(cameraZoom: zoom, strengthScale: 1, flatZoomFade: flat, mountainZoomFade: mountain)
                .fadeAlpha(mountainShare: share)
        }
        XCTAssertEqual(alpha(11, share: 0), flat.alpha(atZoom: 11), accuracy: 1e-6, "Flat ground: the flat fade")
        XCTAssertEqual(alpha(17.5, share: 1), mountain.alpha(atZoom: 17.5), accuracy: 1e-6, "Mountains: the mountain fade")
        // Half a mountain: the fade runs from 13.5 to 15.
        XCTAssertEqual(alpha(13.5, share: 0.5), 1, accuracy: 1e-6, "Full to the blended start")
        XCTAssertEqual(alpha(14.25, share: 0.5), 0.5, accuracy: 1e-6, "Halfway through the blended fade")
        XCTAssertEqual(alpha(15, share: 0.5), 0, accuracy: 1e-6, "Gone at the blended end, nothing left standing")
        XCTAssertEqual(alpha(16.5, share: 0.5), 0, "And still gone where the alphas' blend would have kept half")
        // Most of a mountain, a city beside one: the fade runs from 16.16
        // to 17.28, gone before the mountain fade has begun.
        XCTAssertEqual(alpha(17.3, share: 0.88), 0, accuracy: 0.02)
        XCTAssertEqual(alpha(16.1, share: 0.88), 1, accuracy: 0.02)
        // No flat fade: the relief stays wherever the ground is at all flat.
        XCTAssertEqual(alpha(17.5, share: 0.5, flat: .none), 1, accuracy: 1e-6)
        XCTAssertEqual(alpha(17.5, share: 1, flat: .none), mountain.alpha(atZoom: 17.5), accuracy: 1e-6, "A mountain still fades")
        let frame = GroundReliefFrame(cameraZoom: 14.25, strengthScale: 3, flatZoomFade: flat, mountainZoomFade: mountain)
        XCTAssertEqual(frame.strength(mountainShare: 0.5), 1.5, accuracy: 1e-6, "The strength is the scale times the fade")
        XCTAssertEqual(ImmersiveMapSettings.default.tiles.groundRelief.reliefWindowMetres, 16_000)
        XCTAssertEqual(ImmersiveMapSettings.default.tiles.groundRelief.roughnessZoom, 8)
    }

    /// A tile whose terrain is on its way, at the source's floor, is
    /// drawn with the coarser terrain already in meanwhile, the far rings'
    /// terrain below the floor: without it the tile lay flat for the
    /// frames its own terrain took, a piece of a mountain gone and back.
    /// The floor still ends the search of a tile the source lacks, and an
    /// exact lookup takes nothing coarser.
    func testATileAtTheFloorStandsOnCoarserTerrainWhileItsOwnLoads() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 100, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true,
                                                                              fromTileZoom: 10,
                                                                              minimumSourceZoom: 12)
        // The zoom 12 terrain never arrives, the coarser ones do.
        let store = GroundReliefStore(device: device, settings: settings, fetch: { url in
            if url.path.contains("/12/") { throw URLError(.timedOut) }
            return .image(image)
        })
        let deep = Tile(x: 4823, y: 6160, z: 13)
        let coarse = try XCTUnwrap(deep.findParentTile(atZoom: 11))
        _ = try XCTUnwrap(waitForRelief(of: coarse, in: store), "The far ring's terrain is in")
        let standIn = try XCTUnwrap(waitForRelief(of: deep, in: store), "The deep tile stands on it meanwhile")
        XCTAssertEqual(standIn.scale, 0.25, "Placed in the zoom 11 terrain, a quarter of its side")
        XCTAssertNil(store.relief(for: deep, terrainZoom: 12, orCoarser: false), "Its own terrain is not in")
    }

    // MARK: - Helpers

    private func waitForRelief(of tile: Tile, in store: GroundReliefStore) -> GroundRelief? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let relief = store.relief(for: tile, terrainZoom: tile.z) {
                return relief
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    private static func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("A Metal device is required for the relief textures.")
        }
        return device
    }

    private static func png(size: Int, pixels: [(UInt8, UInt8, UInt8)]) throws -> Data {
        try png(width: size, height: size, pixels: pixels)
    }

    /// An sRGB PNG of the given pixels, row 0 first.
    private static func png(width: Int, height: Int, pixels: [(UInt8, UInt8, UInt8)]) throws -> Data {
        var bytes: [UInt8] = []
        for pixel in pixels {
            bytes += [pixel.0, pixel.1, pixel.2, 255]
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bitsPerPixel: 32,
                                          bytesPerRow: width * 4,
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

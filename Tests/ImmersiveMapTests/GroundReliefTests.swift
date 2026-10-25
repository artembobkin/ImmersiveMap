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
        _ = try Self.device()
        let source = GroundReliefURLTerrainSource(settings: settings, fetch: { _ in .missing })
        XCTAssertEqual(source.url(for: Tile(x: 3, y: 5, z: 4))?.absoluteString, "https://terrain.example/4/3/5.png")
    }

    /// The wanted tiles still on their way are what a still capture waits
    /// for: a tile counts until its terrain is in, and a tile the source
    /// has none for never counts.
    func testTheWantedTilesOnTheirWayAreCounted() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 10, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true, minimumSourceZoom: 14)
        let present = Tile(x: 4823, y: 6160, z: 14)
        let absent = Tile(x: 4824, y: 6160, z: 14)
        let ground = makeTestRelief(device: device, settings: settings, fetch: { url in
            url.absoluteString.contains("/14/\(absent.x)/") ? .missing : .image(image)
        })
        XCTAssertEqual(ground.store.pendingWantedCount, 0, "Nothing wanted, nothing on its way")

        _ = try XCTUnwrap(waitForRelief(of: present, in: ground))
        ground.store.request(tiles: [present])
        XCTAssertEqual(ground.store.pendingWantedCount, 0, "A resident terrain is in")

        ground.store.request(tiles: [present, absent])
        let deadline = Date().addingTimeInterval(5)
        while ground.store.pendingWantedCount > 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            ground.store.request(tiles: [present, absent])
        }
        XCTAssertEqual(ground.store.pendingWantedCount, 0, "A tile the source has no terrain for is not on its way")
    }

    /// The source has no terrain at zoom 15: the tile is flat until its
    /// parent's terrain arrives, and then lies in its quarter of it.
    func testATileWithoutTerrainOfItsOwnRisesByItsParents() throws {
        let device = try Self.device()
        let parentImage = try Self.png(size: 2, pixels: Array(repeating: (128, 10, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true,
                                                                              tileURLTemplate: "https://terrain.example/{z}/{x}/{y}.png",
                                                                              minimumSourceZoom: 12)
        let ground = makeTestRelief(device: device, settings: settings, fetch: { url in
            url.absoluteString.contains("/15/") ? .missing : .image(parentImage)
        })
        let tile = Tile(x: 9647, y: 12321, z: 15)

        XCTAssertNil(ground.frame.relief(for: tile, terrainZoom: tile.z), "Nothing is in before the first load")
        XCTAssertNil(ground.frame.relief(for: tile, terrainZoom: tile.z), "A lookup starts no load: only the frame's demand does")
        let relief = try XCTUnwrap(waitForRelief(of: tile, in: ground))
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
        let ground = makeTestRelief(device: device, settings: settings, fetch: { _ in .image(image) })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: ground))
        let tilesCount = Double(1 << 15)
        let point = SIMD2<Double>((Double(tile.x) + 0.625) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)
        let elevation = try XCTUnwrap(ground.frame.elevation(atNormalizedWorld: point, terrainZoom: 15))
        XCTAssertEqual(elevation, 75, accuracy: 0.01)
        XCTAssertNil(ground.frame.elevation(atNormalizedWorld: SIMD2(0.1, 0.1), terrainZoom: 15), "Terrain not in yet")
    }

    /// The terrain under the point the camera looks at is the frame's
    /// datum, which the relief is drawn from, in the terrain's own metres.
    func testTheTerrainUnderThePointLookedAtIsTheDatum() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 100, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true,
                                                                              exaggeration: 2,
                                                                              minimumSourceZoom: 15,
                                                                              cameraTerrainZoom: 15,
                                                                              cameraClearanceMetres: 30)
        let ground = makeTestRelief(device: device, settings: settings, fetch: { _ in .image(image) })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: ground))
        let tilesCount = Double(1 << 15)
        let centre = SIMD2<Double>((Double(tile.x) + 0.5) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)
        let renderMapSize = 1_000_000.0
        let unitsPerMetre = Float(ImmersiveMapProjection.worldUnitsPerMeter(
            latitudeRadians: ImmersiveMapProjection.latitude(fromNormalizedWorldY: centre.y),
            renderMapSize: renderMapSize))
        let datum = try XCTUnwrap(GroundReliefCameraLift.datumMetres(relief: ground.frame,
                                                                     centerWorldMercator: centre,
                                                                     tileZoom: 16))
        XCTAssertEqual(datum, 100, accuracy: 0.01, "The terrain's own metres, before the exaggeration")
        ground.setDatum(metres: datum)
    }

    /// The centre of the screen meets the terrain as drawn from the datum:
    /// over a terrain 100 m high drawn twice as tall, from a datum of
    /// zero it meets the ground 200 m nearer than the plane, and that is
    /// the depth the road widths are stated at. From the terrain's own
    /// datum, the ground lies at the origin, and the depth is the plane's.
    func testTheCentreOfTheScreenMeetsTheTerrainNotThePlane() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 100, 0), count: 4))
        // Outside a frame the ring of zoom 16 reads its own terrain, and
        // the zoom 15 tile in stands in for it.
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true,
                                                                              exaggeration: 2,
                                                                              minimumSourceZoom: 15)
        let ground = makeTestRelief(device: device, settings: settings, fetch: { _ in .image(image) })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: ground))
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
        // The frame's rise a metre, at the centre's latitude.
        ground.setWorldScale(centerWorldMercator: centre, renderMapSize: renderMapSize)
        let depth = try XCTUnwrap(GroundReliefCameraLift.centreGroundDepth(relief: ground.frame,
                                                                           cameraMatrix: cameraMatrix,
                                                                           centerWorldMercator: centre,
                                                                           tileZoom: 16,
                                                                           renderMapSize: renderMapSize))
        // Along a ray at 60 degrees from the vertical, 200 m of height are
        // 200 / cos(60) = 400 m of depth.
        XCTAssertEqual(depth, planeDepth - 400 * unitsPerMetre, accuracy: unitsPerMetre)
        ground.setDatum(metres: 100)
        let fromTheDatum = try XCTUnwrap(GroundReliefCameraLift.centreGroundDepth(relief: ground.frame,
                                                                                  cameraMatrix: cameraMatrix,
                                                                                  centerWorldMercator: centre,
                                                                                  tileZoom: 16,
                                                                                  renderMapSize: renderMapSize))
        XCTAssertEqual(fromTheDatum, planeDepth, accuracy: unitsPerMetre)
    }

    func testHalfFloatsReadBack() {
        // 1.0, -2.0 and 1000.0 as half floats.
        XCTAssertEqual(GroundReliefTile.floats(halfBits: [0x3C00, 0xC000, 0x63D0]), [1, -2, 1000])
    }

    /// A source with no terrain anywhere down to the minimum zoom leaves
    /// the tile flat, and stops asking.
    func testATileWithoutAnyTerrainStaysFlat() throws {
        let device = try Self.device()
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true, minimumSourceZoom: 14)
        let ground = makeTestRelief(device: device, settings: settings, fetch: { _ in .missing })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        for _ in 0 ..< 20 {
            ground.store.request(tiles: [tile])
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertNil(ground.frame.relief(for: tile, terrainZoom: tile.z))
    }

    func testTheReliefIsOnByDefault() {
        XCTAssertTrue(ImmersiveMapSettings.default.tiles.groundRelief.isEnabled)
        XCTAssertFalse(ImmersiveMapSettings.default.groundRelief(isEnabled: false).tiles.groundRelief.isEnabled)
        let settings = ImmersiveMapSettings.defaultWithoutRelief.groundRelief(isEnabled: true, exaggeration: 3)
        XCTAssertTrue(settings.tiles.groundRelief.isEnabled)
        XCTAssertEqual(settings.tiles.groundRelief.exaggeration, 3)
        XCTAssertEqual(settings.tiles.groundRelief.tileURLTemplate,
                       ImmersiveMapSettings.TileSettings.GroundReliefSettings().tileURLTemplate,
                       "An omitted value is left as configured")
    }

    /// The relief and the flattening start at one zoom: the tile zoom of
    /// the relief's appear zoom, the frame's own tiles when the relief
    /// rises, whatever the flattening's own zoom. A coarser tile, which the
    /// relief shows only from a texture, is parsed in layers.
    func testTheReliefFlattensFromTheZoomItAppearsAt() {
        var settings = ImmersiveMapSettings.defaultWithoutRelief
        XCTAssertEqual(settings.tiles.resolvedGroundFlatteningFromTileZoom, 15, "Off, the flattening's own zoom")
        settings = settings.groundRelief(isEnabled: true)
        XCTAssertEqual(settings.tiles.groundRelief.appearZoom, 10)
        XCTAssertEqual(settings.tiles.resolvedGroundFlatteningFromTileZoom, 10, "The zoom the relief appears at")
        XCTAssertTrue(TileParseOptions(settings: settings).flattensGround(tileZoom: 12))
        XCTAssertTrue(TileParseOptions(settings: settings).flattensGround(tileZoom: 10))
        XCTAssertFalse(TileParseOptions(settings: settings).flattensGround(tileZoom: 9), "A far ring's tile is spared")
        settings = settings.groundRelief(appearZoom: 11.6)
        XCTAssertEqual(settings.tiles.resolvedGroundFlatteningFromTileZoom, 11, "The tile zoom of a fractional appear zoom")
        settings = settings.groundRelief(appearZoom: 30)
        XCTAssertEqual(settings.tiles.resolvedGroundFlatteningFromTileZoom, settings.tiles.coverage.maximumZoomLevel,
                       "Past the tileset, its deepest zoom")
        settings = settings.groundFlattening(isEnabled: false).groundRelief(appearZoom: 10)
        XCTAssertEqual(settings.tiles.resolvedGroundFlatteningFromTileZoom, 10, "The relief flattens on its own")
        settings = settings.groundRelief(appearZoom: 0)
        XCTAssertTrue(TileParseOptions(settings: settings).flattensGround(tileZoom: 3), "Zero flattens every tile")
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
        XCTAssertEqual(TileParseOptions(settings: .default).groundFlatteningGridByTileZoomKey,
                       "0=64,1=64,2=32,3=32,9=128,10=128,11=128,12=128,13=64,14=32",
                       "128 cells on the relief's zooms, a vertex per height of the zoom 10 map from zoom 12 on, and the globe's the sphere's split")
        XCTAssertEqual(TileParseOptions(settings: .default).groundFlatteningGrid(forTileZoom: 15), 16)
        XCTAssertEqual(TileParseOptions(settings: .default).groundFlatteningGrid(forTileZoom: 8), 16, "Beyond the named zooms, the grid")
        for zoom in 0 ... 3 {
            XCTAssertEqual(TileParseOptions(settings: .default).groundFlatteningGrid(forTileZoom: zoom),
                           4096 / (GroundGeometrySubdivider.step(forTileZoom: zoom) ?? 4096),
                           "The globe's flattened tiles are as fine as the sphere's split was at zoom \(zoom)")
        }
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
                                                                              appearZoom: 12,
                                                                              minimumSourceZoom: 10)
        let ground = makeTestRelief(device: device, settings: settings, fetch: { _ in .image(image) })
        let deep = Tile(x: 9647, y: 12321, z: 15)
        let coarse = Tile(x: 9647 >> 4, y: 12321 >> 4, z: 11)
        _ = try XCTUnwrap(waitForRelief(of: deep, in: ground))
        _ = try XCTUnwrap(waitForRelief(of: coarse, in: ground), "On the terrain a coarse far tile rises too")
        let tilesCount = Double(1 << 15)
        let centre = SIMD2<Double>((Double(deep.x) + 0.5) / tilesCount, (Double(deep.y) + 0.5) / tilesCount)
        XCTAssertEqual(ground.frame.elevation(atNormalizedWorld: centre, terrainZoom: 15), 100)
        ground.setActive(false)
        XCTAssertNil(ground.frame.relief(for: deep, terrainZoom: deep.z), "Off the terrain every tile lies on the plane")
        XCTAssertNil(ground.frame.relief(for: coarse, terrainZoom: coarse.z))
        XCTAssertEqual(ground.frame.elevation(atNormalizedWorld: centre, terrainZoom: 15), 0, "The plane under a coarse frame")
        ground.setActive(true)
        XCTAssertEqual(GroundReliefCameraLift.datumMetres(relief: ground.frame,
                                                          centerWorldMercator: centre,
                                                          tileZoom: 11), 0,
                       "The relief over coarse tiles is drawn from the plane")
        XCTAssertEqual(GroundReliefCameraLift.datumMetres(relief: ground.frame,
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
        settings = settings.groundRelief(isEnabled: true, appearZoom: 12)
        settings.tiles.groundRelief.minimumSourceZoom = 15
        settings.tiles.groundRelief.cameraTerrainZoom = 15
        let ground = makeTestRelief(device: device, settings: settings.tiles.groundRelief, fetch: { _ in .image(image) })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: ground))
        let tilesCount = Double(1 << 15)
        let west = SIMD2<Double>((Double(tile.x) + 0.3) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)
        let east = SIMD2<Double>((Double(tile.x) + 0.7) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)

        let controller = CameraStateController(settings: settings.camera)
        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: west, zoom: 16.5, bearing: 0, pitch: 0.5))
        let follow = ground.makeTerrainFollow(tileSettings: settings.tiles,
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
        settings = settings.groundRelief(isEnabled: true, appearZoom: 12)
        settings.tiles.groundRelief.minimumSourceZoom = 15
        settings.tiles.groundRelief.cameraTerrainZoom = 15
        let ground = makeTestRelief(device: device, settings: settings.tiles.groundRelief, fetch: { url in
            .image(url.path.hasSuffix("/9647/12321.webp") ? image : flat)
        })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: ground))
        _ = try XCTUnwrap(waitForRelief(of: Tile(x: 9647, y: 12322, z: 15), in: ground))
        let tilesCount = Double(1 << 15)
        let south = SIMD2<Double>((Double(tile.x) + 0.5) / tilesCount, (Double(tile.y) + 0.8) / tilesCount)

        let controller = CameraStateController(settings: settings.camera)
        controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: south, zoom: 16.5, bearing: 0, pitch: 1.1))
        let follow = ground.makeTerrainFollow(tileSettings: settings.tiles,
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

    /// The relief collapses into the plane at the collapse zoom: full
    /// below it, and from it on an animation in time down to nothing,
    /// the camera's terrain with it, and the rise back the same way.
    func testTheReliefCollapsesAtTheCollapseZoom() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 100, 0), count: 4))
        var settings = ImmersiveMapSettings.default
        settings.tiles.coverage.maximumZoomLevel = 16
        settings = settings.groundRelief(isEnabled: true, exaggeration: 2,
                                         collapseZoom: 14, transitionSeconds: 0.4)
        XCTAssertEqual(ImmersiveMapSettings.default.tiles.groundRelief.collapseZoom, 13.7, "13.7 by default")
        XCTAssertEqual(ImmersiveMapSettings.default.tiles.groundRelief.transitionSeconds, 0.3)
        settings.tiles.groundRelief.minimumSourceZoom = 15
        settings.tiles.groundRelief.cameraTerrainZoom = 15
        let ground = makeTestRelief(device: device, settings: settings.tiles.groundRelief, fetch: { _ in .image(image) })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: ground))
        let tilesCount = Double(1 << 15)
        let centre = SIMD2<Double>((Double(tile.x) + 0.5) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)
        // The camera's terrain is the fixture's zoom 15 map, so the camera
        // stays over the fixture's tile while it collapses.
        var cameraZoom = 16.0
        let follow = ground.makeTerrainFollow(tileSettings: settings.tiles,
                                             globeRadiusScale: settings.presentation.globeRadiusScale,
                                             cameraZoom: { cameraZoom })
        func strength() throws -> Float {
            try XCTUnwrap(ground.frame.strength(atNormalizedWorld: centre, terrainZoom: 15))
        }
        ground.setFrame(zoom: 13.9, deltaTime: 1 / 60)
        XCTAssertEqual(try strength(), 2, "Full below the collapse zoom")
        XCTAssertTrue(ground.isVisible(atZoom: 13.9))
        XCTAssertFalse(ground.isTransitioning)
        ground.setFrame(zoom: 14, deltaTime: 0.2)
        XCTAssertEqual(ground.standingShare, 0.5, accuracy: 1e-6, "Halfway down after half the time")
        XCTAssertEqual(try strength(), 1, accuracy: 1e-6, "Eased: half the share is half the strength")
        XCTAssertTrue(ground.isTransitioning)
        XCTAssertTrue(ground.isVisible(atZoom: 14), "Still on the terrain on the way down")
        XCTAssertEqual(try XCTUnwrap(follow.terrainMetres(centre)), 100, accuracy: 1e-3, "The camera's terrain scales with it")
        ground.setFrame(zoom: 14, deltaTime: 0.2)
        cameraZoom = 17
        XCTAssertEqual(ground.standingShare, 0)
        XCTAssertEqual(try strength(), 0, "Collapsed")
        XCTAssertFalse(ground.isTransitioning)
        XCTAssertFalse(ground.isVisible(atZoom: 14), "And the frame is off the terrain once collapsed")
        XCTAssertEqual(try XCTUnwrap(follow.terrainMetres(centre)), 0)
        XCTAssertEqual(ground.frame.elevation(atNormalizedWorld: centre, terrainZoom: 15), 100, "The heights themselves are untouched")
        ground.setFrame(zoom: 13, deltaTime: 0.1)
        XCTAssertEqual(ground.standingShare, 0.25, accuracy: 1e-6, "Rising back at the same pace")
        XCTAssertTrue(ground.isVisible(atZoom: 13), "On the terrain the moment the zoom is back")
        ground.setFrame(zoom: 13, snap: true)
        XCTAssertEqual(try strength(), 2, "A snap settles it at once")
        ground.setFrame(zoom: 16)
        XCTAssertEqual(try strength(), 0, "Without a frame time the collapse is settled where the zoom puts it")
        let everywhere = makeTestRelief(device: device,
                                           settings: settings.groundRelief(collapseZoom: 30).tiles.groundRelief,
                                           fetch: { _ in .image(image) })
        _ = try XCTUnwrap(waitForRelief(of: tile, in: everywhere))
        everywhere.setFrame(zoom: 20)
        XCTAssertEqual(try XCTUnwrap(everywhere.frame.strength(atNormalizedWorld: centre, terrainZoom: 15)), 2,
                       "A collapse zoom past the deepest keeps the relief at every zoom")
        XCTAssertTrue(everywhere.isVisible(atZoom: 20))
    }

    /// The relief rises when the zoom crosses `appearZoom`: flat below
    /// it, up over `transitionSeconds` once the zoom is past it, never
    /// scaled with the zoom itself, with the collapse on top. The
    /// camera's terrain follows, so below the appear zoom the camera
    /// stands on the plane.
    func testTheReliefRisesAtTheAppearZoom() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 100, 0), count: 4))
        var settings = ImmersiveMapSettings.default
        settings.tiles.coverage.maximumZoomLevel = 16
        settings = settings.groundRelief(isEnabled: true, exaggeration: 2,
                                         appearZoom: 10, collapseZoom: 15, transitionSeconds: 0.4)
        XCTAssertEqual(ImmersiveMapSettings.default.tiles.groundRelief.appearZoom, 10, "10 by default")
        settings.tiles.groundRelief.minimumSourceZoom = 15
        settings.tiles.groundRelief.cameraTerrainZoom = 15
        let ground = makeTestRelief(device: device, settings: settings.tiles.groundRelief, fetch: { _ in .image(image) })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        _ = try XCTUnwrap(waitForRelief(of: tile, in: ground))
        let tilesCount = Double(1 << 15)
        let centre = SIMD2<Double>((Double(tile.x) + 0.5) / tilesCount, (Double(tile.y) + 0.5) / tilesCount)
        let follow = ground.makeTerrainFollow(tileSettings: settings.tiles,
                                             globeRadiusScale: settings.presentation.globeRadiusScale,
                                             cameraZoom: { 16 })
        func strength() throws -> Float {
            try XCTUnwrap(ground.frame.strength(atNormalizedWorld: centre, terrainZoom: 15))
        }
        ground.setFrame(zoom: 9.5)
        XCTAssertEqual(try strength(), 0, "Flat below the appear zoom")
        XCTAssertFalse(ground.isVisible(atZoom: 9.5), "And the frame is off the terrain there")
        XCTAssertEqual(try XCTUnwrap(follow.terrainMetres(centre)), 0, "The camera stands on the plane")
        XCTAssertTrue(ground.isVisible(atZoom: 10))
        XCTAssertTrue(ground.isVisible(atZoom: 14.9), "On it up to the collapse")
        ground.setFrame(zoom: 10.5, deltaTime: 0.2)
        XCTAssertEqual(ground.standingShare, 0.5, accuracy: 1e-6, "Halfway up after half the time")
        XCTAssertEqual(try strength(), 1, accuracy: 1e-6, "Eased: half the share is half the strength")
        XCTAssertTrue(ground.isTransitioning)
        XCTAssertEqual(try XCTUnwrap(follow.terrainMetres(centre)), 100, accuracy: 1e-3, "The camera's terrain rises with it")
        ground.setFrame(zoom: 10.1, deltaTime: 0.2)
        XCTAssertEqual(try strength(), 2, "Full once risen, whatever the zoom within the relief's zooms")
        ground.setFrame(zoom: 12.7, deltaTime: 1 / 60)
        XCTAssertEqual(try strength(), 2, "A zoom's move within them changes nothing: no breathing")
        ground.setFrame(zoom: 15)
        XCTAssertEqual(try strength(), 0, "The collapse takes it away again on top")
        let atOnce = makeTestRelief(device: device,
                                       settings: settings.groundRelief(appearZoom: 0).tiles.groundRelief,
                                       fetch: { _ in .image(image) })
        _ = try XCTUnwrap(waitForRelief(of: tile, in: atOnce))
        atOnce.setFrame(zoom: 5)
        XCTAssertEqual(try XCTUnwrap(atOnce.frame.strength(atNormalizedWorld: centre, terrainZoom: 15)), 2,
                       "An appear zoom of 0 draws the relief from the plane's first frame")
    }

    /// A tile whose terrain is on its way, at the source's floor, is
    /// drawn with the coarser terrain already in meanwhile, the far rings'
    /// terrain below the floor: without it the tile lay flat for the
    /// frames its own terrain took, a piece of a mountain gone and back.
    /// The floor ends the search of a tile the source lacks: a missing
    /// tile above it binds the finest ancestor the source has, a missing
    /// tile at the floor counts as in and flat, and no load goes below it.
    func testTheFloorEndsTheSearchForAMissingTile() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 100, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true,
                                                                              minimumSourceZoom: 12)
        // The source has nothing at zooms 12 and 13.
        let ground = makeTestRelief(device: device, settings: settings, fetch: { url in
            url.path.contains("/13/") || url.path.contains("/12/") ? .missing : .image(image)
        })
        let deep = Tile(x: 4823, y: 6160, z: 13)
        let floor = try XCTUnwrap(deep.findParentTile(atZoom: 12))
        ground.setBands([FlatRingBand(zoom: 13, distance: 1, tileCount: 9, terrainZoom: 13)])
        XCTAssertTrue(waitUntil { ground.store.request(tiles: [deep]); return ground.frame.statusSnapshot().missingCount == 2 },
                      "Zoom 13 is missing, then its parent at the floor")
        XCTAssertEqual(ground.store.terrainSource(for: deep, targetZoom: 13), floor, "The search ends at the floor")
        ground.store.request(tiles: [deep])
        XCTAssertEqual(ground.frame.statusSnapshot().wantedCount, 0, "Nothing to load: no load goes below the floor")
        XCTAssertTrue(ground.store.isResident(floor), "The source has nothing here: the tile is placed, flat")
        XCTAssertNil(ground.frame.relief(for: deep, terrain: floor), "Bound to a tile that cannot come: drawn flat")
    }

    /// A terrain source out of reach: a tile whose load has failed
    /// `unavailableAfterAttempts` times counts as in and flat, so the map
    /// tiles over it are placed on the plane instead of waiting, and the
    /// store's version moves so the frame plans over it. The retries go
    /// on, and the tile rises when one succeeds.
    func testATileTheSourceDoesNotAnswerForCountsAsInAndFlat() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 100, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true, minimumSourceZoom: 12)
        struct Unreachable: Error {}
        nonisolated(unsafe) var answers = false
        nonisolated(unsafe) var clock: TimeInterval = 1000
        let ground = makeTestRelief(device: device, settings: settings,
                                      fetch: { _ in
                                          if answers { return .image(image) }
                                          throw Unreachable()
                                      },
                                      now: { clock })
        let tile = Tile(x: 4823, y: 6160, z: 13)
        ground.setBands([FlatRingBand(zoom: 13, distance: 1, tileCount: 9, terrainZoom: 13)])
        ground.store.request(tiles: [tile])
        XCTAssertTrue(waitUntil { ground.frame.statusSnapshot().loadingCount == 0 }, "The first attempt fails")
        XCTAssertFalse(ground.store.isResident(tile), "One failure may be a dropped connection")
        let versionBefore = ground.store.version
        clock += GroundReliefLoadStates.retryBaseDelay + 1
        XCTAssertTrue(waitUntil { ground.store.request(tiles: [tile]); return ground.store.isResident(tile) },
                      "The second failure says the source is out of reach: in, and flat")
        XCTAssertNil(ground.frame.relief(for: tile, terrain: tile), "Drawn flat")
        XCTAssertNotEqual(ground.store.version, versionBefore, "The frame plans over it")
        answers = true
        clock += GroundReliefLoadStates.retryMaximumDelay + 1
        XCTAssertTrue(waitUntil { ground.store.request(tiles: [tile]); return ground.frame.relief(for: tile, terrain: tile) != nil },
                      "The retries go on: the tile rises when the source answers")
    }

    /// Past the relief's zooms the demand asks for the terrain of the
    /// collapse zoom's tiles over the targets, the ones the relief reads
    /// when it rises back, not the street tiles' own. And the terrain the
    /// planner wanted and found out comes last.
    func testTheDemandIsCappedAtTheCollapseZoomAndAsksWhatThePlannerWanted() {
        let zooms = GroundReliefTerrainZooms(cameraZoom: 10, bands: [FlatRingBand(zoom: 17, distance: 1, tileCount: 9, terrainZoom: 17)])
        let point = SIMD2<Double>((300 + 0.8) / 1024, (400 + 0.3) / 1024)
        let streets = (0 ..< 4).map { VisibleTile(tile: Tile(x: 38500 + $0 % 2, y: 51240 + $0 / 2, z: 17)) }
        let wanted = Tile(x: 2406, y: 3202, z: 13)
        let tiles = GroundReliefDemand.tiles(targets: streets, shown: [], also: [wanted], centerWorldMercator: point, zooms: zooms,
                                             maximumTargetZoom: 13,
                                             terrainSource: { tile, _ in (tile, tile) })
        XCTAssertFalse(tiles.contains { $0.z == 17 }, "No street tile's own terrain")
        XCTAssertEqual(Set(tiles.filter { $0.z == 13 }), Set([streets[0].tile.findParentTile(atZoom: 13)!, wanted]),
                       "The four street tiles' one zoom 13 ancestor, and what the planner wanted")
        XCTAssertEqual(tiles.last, wanted, "What the planner wanted, last")
    }

    /// A placement is bound to one terrain tile, the ring's over it, and
    /// drawn out of that tile alone: a source the frame has no such tile
    /// for (`minimumSourceZoom`) binds the finest ancestor it has.
    func testAPlacementIsBoundToItsRingsTerrain() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 100, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true, minimumSourceZoom: 12)
        // The source has no zoom 13 tiles.
        let ground = makeTestRelief(device: device, settings: settings, fetch: { url in
            url.path.contains("/13/") ? .missing : .image(image)
        })
        let tile = Tile(x: 4823, y: 6160, z: 13)
        let parent = try XCTUnwrap(tile.findParentTile(atZoom: 12))
        ground.setBands([FlatRingBand(zoom: 13, distance: 1, tileCount: 9, terrainZoom: 13)])
        XCTAssertEqual(ground.store.terrainSource(for: tile, targetZoom: 13), tile, "The ring's own, until the source says it has none")
        XCTAssertFalse(ground.store.isResident(tile))
        XCTAssertNil(ground.frame.relief(for: tile, terrain: tile), "Not in: no relief, and no stand-in for it")
        ground.store.request(tiles: [tile])
        XCTAssertTrue(waitUntil { ground.store.request(tiles: [tile]); return ground.store.isResident(parent) })
        XCTAssertEqual(ground.store.terrainSource(for: tile, targetZoom: 13), parent, "The finest the source has")
        let relief = try XCTUnwrap(ground.frame.relief(for: tile, terrain: parent))
        XCTAssertEqual(relief.scale, 0.5, "Placed in the zoom 12 terrain, half its side")
        XCTAssertNil(ground.frame.relief(for: parent, terrain: tile), "A terrain finer than the tile cannot raise it")
        ground.setActive(false)
        XCTAssertEqual(ground.store.terrainSource(for: tile, targetZoom: 13), parent,
                       "Collapsed, the rings' terrain is still named and kept: the rise back binds it at once")
        XCTAssertNil(ground.frame.relief(for: tile, terrain: parent), "And off the terrain nothing rises")
    }

    /// The terrain lives while a frame asks for it, for a target or for a
    /// placement shown, and goes with the next demand that does not: no
    /// budget, the tiles' own lifetime (`TileRenderStore`). A load the
    /// frame stopped wanting lands into nothing. Without the released
    /// cache a tile asked for again is loaded again.
    func testTheTerrainLivesWhileAFrameWantsIt() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 0, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true, minimumSourceZoom: 12,
                                                                              releasedCacheBytes: 0)
        let ground = makeTestRelief(device: device, settings: settings, fetch: { _ in .image(image) })
        let tiles = [Tile(x: 2412, y: 3080, z: 13), Tile(x: 2413, y: 3080, z: 13), Tile(x: 2412, y: 3081, z: 13)]
        ground.store.request(tiles: tiles)
        XCTAssertTrue(waitUntil { ground.frame.statusSnapshot().wantedResidentCount == 3 })
        let next = Tile(x: 2413, y: 3081, z: 13)
        ground.store.request(tiles: [next])
        XCTAssertEqual(ground.frame.statusSnapshot().residentCount, 0, "The three no frame wants any more went at once")
        XCTAssertTrue(waitUntil { ground.store.isResident(next) })
        XCTAssertEqual(ground.frame.statusSnapshot().residentCount, 1)
        ground.store.request(tiles: [tiles[0], next])
        XCTAssertTrue(waitUntil { ground.store.isResident(tiles[0]) })
        XCTAssertEqual(ground.frame.statusSnapshot().residentCount, 2, "Asked for again, it is loaded again")
    }

    /// The released cache: a tile the frame stopped reading waits in it,
    /// up to the cache's bytes with the oldest released let go first, and
    /// comes back without a load when a frame reads it again. The store's
    /// version moves either way.
    func testAReleasedTileComesBackFromTheCacheWithoutALoad() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 0, 0), count: 4))
        let loads = Locked(0)
        func makeStore(cacheBytes: Int) -> GroundReliefFrameState {
            let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true, minimumSourceZoom: 12,
                                                                                  releasedCacheBytes: cacheBytes)
            return makeTestRelief(device: device, settings: settings, fetch: { _ in
                loads.withLock { $0 += 1 }
                return .image(image)
            })
        }
        let tiles = [Tile(x: 2412, y: 3080, z: 13), Tile(x: 2413, y: 3080, z: 13), Tile(x: 2412, y: 3081, z: 13)]
        let next = Tile(x: 2413, y: 3081, z: 13)

        let ground = makeStore(cacheBytes: 50 << 20)
        ground.store.request(tiles: tiles)
        XCTAssertTrue(waitUntil { ground.frame.statusSnapshot().wantedResidentCount == 3 })
        let costPerTile = ground.frame.statusSnapshot().residentBytes / 3
        XCTAssertGreaterThan(costPerTile, 0)
        let loadsBefore = loads.withLock { $0 }
        let versionBefore = ground.store.version
        ground.store.request(tiles: [next])
        var status = ground.frame.statusSnapshot()
        XCTAssertEqual(status.residentCount, 0, "The three no frame wants any more are not the frame's")
        XCTAssertEqual(status.releasedCount, 3, "They wait in the cache")
        XCTAssertEqual(status.releasedBytes, costPerTile * 3)
        XCTAssertNotEqual(ground.store.version, versionBefore)
        XCTAssertTrue(waitUntil { ground.store.isResident(next) })
        ground.store.request(tiles: [tiles[0], next])
        XCTAssertTrue(ground.store.isResident(tiles[0]), "Back from the cache at once")
        XCTAssertEqual(loads.withLock { $0 }, loadsBefore + 1, "One load for the new tile, none for the tile back")
        status = ground.frame.statusSnapshot()
        XCTAssertEqual(status.residentCount, 2)
        XCTAssertEqual(status.releasedCount, 2)
        XCTAssertNotNil(ground.frame.relief(for: tiles[0], terrain: tiles[0]), "Read as a loaded tile is")

        // Room for two tiles: the oldest released goes first.
        let small = makeStore(cacheBytes: costPerTile * 2)
        small.store.request(tiles: tiles)
        XCTAssertTrue(waitUntil { small.frame.statusSnapshot().wantedResidentCount == 3 })
        small.store.request(tiles: [])
        status = small.frame.statusSnapshot()
        XCTAssertEqual(status.releasedCount, 2, "Two fit")
        XCTAssertLessThanOrEqual(status.releasedBytes, costPerTile * 2)
        small.store.request(tiles: [tiles[0]])
        XCTAssertFalse(small.store.isResident(tiles[0]) && small.frame.statusSnapshot().releasedCount == 2,
                       "The first released was let go when the third came: it loads again")
        small.store.removeAll()
        XCTAssertEqual(small.frame.statusSnapshot().releasedCount, 0, "A memory warning empties the cache too")
    }

    /// The demand: the camera's nine tiles first, then the targets' terrain
    /// by the target's distance, then what the placements shown rise by.
    func testTheDemandAsksForTheCamerasMapThenTheTargetsThenTheShown() throws {
        let zooms = GroundReliefTerrainZooms(cameraZoom: 10, bands: [FlatRingBand(zoom: 13, distance: 1, tileCount: 9, terrainZoom: 13),
                                                                      FlatRingBand(zoom: 12, distance: 3, tileCount: 9, terrainZoom: 10)])
        // A point in the north-east quarter of its zoom 10 tile.
        let point = SIMD2<Double>((300 + 0.8) / 1024, (400 + 0.3) / 1024)
        let near = VisibleTile(tile: Tile(x: 2406, y: 3202, z: 13))
        let far = VisibleTile(tile: Tile(x: 1300, y: 1700, z: 12))
        let shownTerrain = Tile(x: 2405, y: 3202, z: 13)
        let metalTile = MetalTile(tile: Tile(x: 2405, y: 3202, z: 13), tileBuffers: try TileBuffersFixtures.makeEmptyTileBuffers())
        let shown = PlaceTile(metalTile: metalTile, placeIn: VisibleTile(tile: metalTile.tile), terrain: shownTerrain)
        let tiles = GroundReliefDemand.tiles(targets: [far, near], shown: [shown], centerWorldMercator: point, zooms: zooms,
                                             terrainSource: { tile, targetZoom in
                                                 (zooms.terrainTile(for: tile, targetZoom: targetZoom),
                                                  zooms.displacementTile(for: tile, targetZoom: targetZoom))
                                             })
        XCTAssertEqual(tiles.count, 9 + 2 + 1)
        XCTAssertEqual(tiles.first, Tile(x: 300, y: 400, z: 10), "The tile under the point first")
        XCTAssertTrue(tiles.prefix(9).allSatisfy { $0.z == 10 })
        XCTAssertEqual(tiles[9], near.tile, "The near target's own terrain before the far target's, its zoom 10 map the camera's")
        XCTAssertEqual(tiles[10], far.tile.findParentTile(atZoom: 10), "The far target's ring reads zoom 10")
        XCTAssertEqual(tiles[11], shownTerrain, "What the placement shown rises by, last")
        XCTAssertEqual(GroundReliefDemand.ring(around: SIMD2(0.5, 0.5), zoom: 0), [Tile(x: 0, y: 0, z: 0)])
    }

    // MARK: - The terrain by ring

    /// The camera's map and the cache are settings of their own, the
    /// terrain each ring reads is its rule's.
    func testTheCameraMapAndTheCacheAreTheSettings() {
        let relief = ImmersiveMapSettings.TileSettings.GroundReliefSettings()
        XCTAssertEqual(relief.cameraTerrainZoom, 10)
        XCTAssertEqual(ImmersiveMapSettings.default.groundRelief(cameraTerrainZoom: -3).tiles.groundRelief.cameraTerrainZoom, 0)
        XCTAssertEqual(relief.displacementMaximumZoom, 10)
        XCTAssertEqual(ImmersiveMapSettings.default.groundRelief(displacementMaximumZoom: 13).tiles.groundRelief.displacementMaximumZoom, 13)
        XCTAssertEqual(relief.releasedCacheBytes, 50 << 20)
        XCTAssertEqual(ImmersiveMapSettings.default.groundRelief(releasedCacheBytes: -1).tiles.groundRelief.releasedCacheBytes, 0)
    }

    /// The default rules: the near ring on the terrain of its own zoom,
    /// the bands past it three zooms under the near tiles and the far
    /// band seven under. A drop outside the range is clamped.
    func testTheDefaultRulesReadTheNearRingsOwnTerrain() {
        XCTAssertEqual(FlatRingRules.default.rules.map(\.terrainZoomDrop), [0, 2, 1, 3])
        XCTAssertEqual(FlatRingRules.default.rules.map { $0.zoomDrop + $0.terrainZoomDrop }, [0, 3, 3, 7],
                       "Under the near tiles' zoom")
        let wild = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 1, terrainZoomDrop: 99),
                                         FlatRingRule(zoomDrop: 1, distance: 2, terrainZoomDrop: -4)])
        XCTAssertEqual(wild.normalized().rules.map(\.terrainZoomDrop), [8, 0])
        XCTAssertEqual(FlatRingRule(zoomDrop: 2, distance: 3).terrainZoomDrop, 0, "Own terrain unless said otherwise")
    }

    /// The frame's bands give each ring its terrain zoom: the band's zoom
    /// less its rule's drop, the nearer band's where two share a zoom, and
    /// a zoom without a band reads its own.
    func testEachRingReadsTheTerrainItsBandGivesIt() {
        let bands = [FlatRingBand(zoom: 13, distance: 1, tileCount: 9, terrainZoom: 13),
                     FlatRingBand(zoom: 12, distance: 2, tileCount: 7, terrainZoom: 10),
                     FlatRingBand(zoom: 12, distance: 3, tileCount: 7, terrainZoom: 8),
                     FlatRingBand(zoom: 9, distance: 9, tileCount: 20, terrainZoom: 6)]
        let zooms = GroundReliefTerrainZooms(cameraZoom: 10, bands: bands)
        XCTAssertEqual(zooms.cameraZoom, 10)
        XCTAssertEqual((9 ... 14).map(zooms.terrainZoom(forTargetZoom:)), [6, 10, 11, 10, 13, 14])
        XCTAssertEqual((9 ... 14).map(zooms.displacementZoom(forTargetZoom:)), [6, 10, 10, 10, 10, 10],
                       "The grid rises by terrain no finer than zoom 10")
        let near = Tile(x: 4823, y: 6160, z: 13)
        XCTAssertEqual(zooms.displacementTile(for: near, targetZoom: 13), near.findParentTile(atZoom: 10))
        XCTAssertEqual(zooms.terrainTile(for: near, targetZoom: 13), near, "Shaded by its own")
        XCTAssertEqual(GroundReliefTerrainZooms(cameraZoom: 10, displacementMaximumZoom: 13, bands: bands)
                           .displacementTile(for: near, targetZoom: 13), near, "Raised, the grid rises by its own")
        XCTAssertEqual(zooms.statusText, "z13→z13 z12→z10 z9→z6")
        let deep = Tile(x: 9647, y: 12321, z: 15)
        XCTAssertEqual(zooms.terrainTile(for: deep, targetZoom: 12), deep.findParentTile(atZoom: 10))
        XCTAssertEqual(zooms.terrainTile(for: deep, targetZoom: 13), deep.findParentTile(atZoom: 13))
        let coarse = Tile(x: 37, y: 48, z: 7)
        XCTAssertEqual(zooms.terrainTile(for: coarse, targetZoom: 13), coarse,
                       "A stand-in coarser than the ring's terrain reads its own address")
        XCTAssertEqual(FlatRingBand(zoom: 11, distance: 2, tileCount: 1).terrainZoom, 11, "Nil is the band's own")
        XCTAssertEqual(GroundReliefTerrainZooms(cameraZoom: 12).terrainZoom(forTargetZoom: 15), 15,
                       "No bands: a ground outside a frame reads each tile's own terrain")
    }

    // MARK: - The hillshade

    /// The slopes are shaded by the scene's light at the style's intensity,
    /// times how far the relief has risen, and not at all by a light at or
    /// under the horizon.
    func testTheSlopesAreShadedByTheScenesLightAsTheReliefRises() {
        let style = ImmersiveMapHillshade(intensity: 0.8)
        let eye = SIMD3<Float>(0, -30, 40)
        let risen = GroundReliefHillshade.resolve(style: style, lightDirection: SIMD3(0, 3, 4), risenShare: 1, cameraEye: eye,
                                                  zoom: 14, unitsPerMetre: 0.01)
        XCTAssertEqual(risen.light.x, 0, accuracy: 1e-6)
        XCTAssertEqual(risen.light.y, 0.6, accuracy: 1e-6)
        XCTAssertEqual(risen.light.z, 0.8, accuracy: 1e-6)
        XCTAssertEqual(risen.light.w, 0.8, accuracy: 1e-6, "The style's intensity")
        XCTAssertEqual(risen.shadowColor, style.shadowColor)
        XCTAssertEqual(GroundReliefHillshade.resolve(style: style, lightDirection: SIMD3(0, 3, 4), risenShare: 0.5,
                                                     cameraEye: eye, zoom: 14, unitsPerMetre: 0.01).light.w,
                       0.4, accuracy: 1e-6, "Half risen, half shaded")
        XCTAssertEqual(GroundReliefHillshade.resolve(style: style, lightDirection: SIMD3(1, 0, -0.1), risenShare: 1,
                                                     cameraEye: eye, zoom: 14, unitsPerMetre: 0.01), .none)
        XCTAssertEqual(GroundReliefHillshade.resolve(style: .none, lightDirection: SIMD3(0, 3, 4), risenShare: 1,
                                                     cameraEye: eye, zoom: 14, unitsPerMetre: 0.01), .none)
        XCTAssertEqual(ProtomapsBasemapTheme.default.apply { $0.hillshade = .none }.cacheFingerprint,
                       ProtomapsBasemapTheme.default.cacheFingerprint,
                       "Drawn at frame time, so no tile is prepared again")
    }

    /// The shading fades with the distance from the eye, in metres by the
    /// zoom: from 4 km out to 8 km at zoom 14 by default, halving a zoom
    /// up, the panel's curves in place of the style's once dragged.
    func testTheShadingFadesInMetresByTheZoom() {
        let eye = SIMD3<Float>(0, -30, 40)
        let shading = GroundReliefHillshade.resolve(style: ImmersiveMapHillshade(), lightDirection: SIMD3(0, 0, 1),
                                                    risenShare: 1, cameraEye: eye, zoom: 14, unitsPerMetre: 0.01)
        XCTAssertEqual(SIMD3(shading.eye.x, shading.eye.y, shading.eye.z), eye)
        XCTAssertEqual(shading.fade.x, 40, accuracy: 1e-3, "From 4 km, a hundredth of a unit a metre")
        XCTAssertEqual(shading.fade.y, 1 / 40, accuracy: 1e-6, "Out over 4 km more")
        let zoomedIn = GroundReliefHillshade.resolve(style: ImmersiveMapHillshade(), lightDirection: SIMD3(0, 0, 1),
                                                     risenShare: 1, cameraEye: eye, zoom: 15, unitsPerMetre: 0.01)
        XCTAssertEqual(zoomedIn.fade.x, 20, accuracy: 1e-2, "Geometric between the stops: half a zoom up")
        let dragged = GroundReliefHillshade.resolve(style: ImmersiveMapHillshade(), lightDirection: SIMD3(0, 0, 1),
                                                    risenShare: 1, cameraEye: eye, zoom: 14, unitsPerMetre: 0.01,
                                                    fade: GroundReliefHillshade.Fade(startMeters: 1000, endMeters: 1500))
        XCTAssertEqual(dragged.fade.x, 10, accuracy: 1e-3)
        XCTAssertEqual(dragged.fade.y, 1 / 5, accuracy: 1e-6)
        XCTAssertEqual(GroundReliefHillshade.resolve(style: ImmersiveMapHillshade(), lightDirection: SIMD3(0, 0, 1),
                                                     risenShare: 1, cameraEye: eye, zoom: 14, unitsPerMetre: 0),
                       .none, "No rise known, no shading")
    }

    /// A terrain texture spans its tile's side over the tile's share of it:
    /// a zoom 1 tile is half the world, and its child's terrain, half of it.
    func testTheTerrainTextureSpansItsTilesSideOverItsShare() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 0, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true, minimumSourceZoom: 0)
        let ground = makeTestRelief(device: device, settings: settings, fetch: { _ in .image(image) })
        let parent = Tile(x: 0, y: 0, z: 1)
        _ = try XCTUnwrap(waitForRelief(of: parent, in: ground))
        let child = Tile(x: 1, y: 1, z: 2)
        let relief = try XCTUnwrap(ground.frame.relief(for: child, terrainZoom: 1, orCoarser: false))
        XCTAssertEqual(relief.scale, 0.5)
        let renderMapSize = 1_000_000.0
        let unitsPerMetre = GroundReliefUniform.worldUnitsPerMetre(atNormalizedWorldY: 0.625, renderMapSize: renderMapSize)
        let metres = GroundReliefUniform.terrainSideMetres(of: relief, over: child,
                                                           worldUnitsPerMetre: unitsPerMetre,
                                                           renderMapSize: renderMapSize)
        XCTAssertEqual(metres * unitsPerMetre, Float(renderMapSize / 2), accuracy: 1)
    }

    // MARK: - The edges' weld

    /// Two neighbours of one zoom meet on their shared edge with one
    /// height, the mean of the two pixels across it, whichever came first,
    /// on the CPU and in the textures alike. The insides keep theirs.
    func testNeighboursOfOneZoomMeetWithOneHeightInAnyOrder() throws {
        let device = try Self.device()
        let commandQueue = try XCTUnwrap(device.makeCommandQueue())
        let west = Tile(x: 100, y: 100, z: 8)
        let east = Tile(x: 101, y: 100, z: 8)
        for order in [[west, east], [east, west]] {
            let ground = try makeWeldStore(device: device, metresByTile: [west: 100, east: 200])
            var loaded: [Tile] = []
            for tile in order {
                loaded.append(tile)
                ground.store.request(tiles: loaded)
                XCTAssertTrue(waitUntil { ground.frame.statusSnapshot().wantedResidentCount == loaded.count })
                ground.store.applyPendingWelds(commandQueue: commandQueue)?.waitUntilCompleted()
            }
            let westRelief = try XCTUnwrap(ground.frame.relief(for: west, terrainZoom: 8, orCoarser: false))
            let eastRelief = try XCTUnwrap(ground.frame.relief(for: east, terrainZoom: 8, orCoarser: false))
            XCTAssertEqual(westRelief.metres(atTileUV: SIMD2(1, 0.5)), 150, accuracy: 0.01, "The west side of the edge")
            XCTAssertEqual(eastRelief.metres(atTileUV: SIMD2(0, 0.5)), 150, accuracy: 0.01, "The east side of the edge")
            XCTAssertEqual(westRelief.metres(atTileUV: SIMD2(0.5, 0.5)), 100, accuracy: 0.01, "The inside keeps its height")
            XCTAssertEqual(Self.textureMetres(westRelief.terrain, x: 3, y: 1), 150, accuracy: 0.01, "The texture took the weld")
            XCTAssertEqual(Self.textureMetres(eastRelief.terrain, x: 0, y: 2), 150, accuracy: 0.01)
            XCTAssertEqual(Self.textureMetres(westRelief.terrain, x: 0, y: 1), 100, accuracy: 0.01,
                           "An edge with no neighbour in is left as decoded")
        }
    }

    /// Where four tiles meet, each takes the mean of the four corners, and
    /// each edge the mean of its two sides.
    func testFourTilesMeetAtTheirCornerWithOneHeight() throws {
        let device = try Self.device()
        let commandQueue = try XCTUnwrap(device.makeCommandQueue())
        let northWest = Tile(x: 100, y: 100, z: 8)
        let northEast = Tile(x: 101, y: 100, z: 8)
        let southWest = Tile(x: 100, y: 101, z: 8)
        let southEast = Tile(x: 101, y: 101, z: 8)
        let ground = try makeWeldStore(device: device, metresByTile: [northWest: 100, northEast: 200, southWest: 300, southEast: 400])
        let tiles = [northWest, northEast, southWest, southEast]
        ground.store.request(tiles: tiles)
        XCTAssertTrue(waitUntil { ground.frame.statusSnapshot().wantedResidentCount == 4 })
        ground.store.applyPendingWelds(commandQueue: commandQueue)?.waitUntilCompleted()
        let reliefs = try tiles.map { try XCTUnwrap(ground.frame.relief(for: $0, terrainZoom: 8, orCoarser: false)) }
        XCTAssertEqual(reliefs[0].metres(atTileUV: SIMD2(1, 1)), 250, accuracy: 0.01)
        XCTAssertEqual(reliefs[1].metres(atTileUV: SIMD2(0, 1)), 250, accuracy: 0.01)
        XCTAssertEqual(reliefs[2].metres(atTileUV: SIMD2(1, 0)), 250, accuracy: 0.01)
        XCTAssertEqual(reliefs[3].metres(atTileUV: SIMD2(0, 0)), 250, accuracy: 0.01)
        XCTAssertEqual(reliefs[0].metres(atTileUV: SIMD2(0.5, 1)), 200, accuracy: 0.01, "The north-west and south-west edge")
        XCTAssertEqual(Self.textureMetres(reliefs[3].terrain, x: 0, y: 0), 250, accuracy: 0.01)
        XCTAssertNil(ground.store.applyPendingWelds(commandQueue: commandQueue), "Nothing left to write")
    }

    /// North and south neighbours rise a metre by one amount, the frame's
    /// at the latitude the camera looks at: their shared edge, one height
    /// after the weld, lies at one rise, with no seam between them.
    func testNorthAndSouthNeighboursRiseByTheFramesOneScale() throws {
        let device = try Self.device()
        let commandQueue = try XCTUnwrap(device.makeCommandQueue())
        let north = Tile(x: 100, y: 100, z: 8)
        let south = Tile(x: 100, y: 101, z: 8)
        let ground = try makeWeldStore(device: device, metresByTile: [north: 300, south: 500])
        ground.store.request(tiles: [north, south])
        XCTAssertTrue(waitUntil { ground.frame.statusSnapshot().wantedResidentCount == 2 })
        ground.store.applyPendingWelds(commandQueue: commandQueue)?.waitUntilCompleted()
        ground.setWorldScale(centerWorldMercator: SIMD2(0.39, 0.39), renderMapSize: 1_000_000)
        XCTAssertGreaterThan(ground.frame.worldUnitsPerMetre, 0)
        let northLift = try XCTUnwrap(GroundReliefTileLift(relief: ground.frame, tile: north, terrain: north))
        let southLift = try XCTUnwrap(GroundReliefTileLift(relief: ground.frame, tile: south, terrain: south))
        XCTAssertEqual(northLift.unitsPerMetre, southLift.unitsPerMetre)
        XCTAssertEqual(northLift.worldUnits(atTileUV: SIMD2(0.5, 1)), southLift.worldUnits(atTileUV: SIMD2(0.5, 0)),
                       "The shared edge rises as one")
    }

    /// A store serving terrain tiles of 4 by 4 pixels, each of one height.
    private func makeWeldStore(device: MTLDevice, metresByTile: [Tile: Int]) throws -> GroundReliefFrameState {
        var images: [String: Data] = [:]
        for (tile, metres) in metresByTile {
            // Terrarium: red × 256 + green − 32768.
            let pixel = (UInt8(128 + metres / 256), UInt8(metres % 256), UInt8(0))
            images["/\(tile.z)/\(tile.x)/\(tile.y).webp"] = try Self.png(size: 4, pixels: Array(repeating: pixel, count: 16))
        }
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true, minimumSourceZoom: 0)
        let served = images
        return makeTestRelief(device: device, settings: settings, fetch: { url in
            served[url.path].map { .image($0) } ?? .missing
        })
    }

    /// A texel of a terrain tile's texture as the GPU holds it, in metres.
    private static func textureMetres(_ terrain: GroundReliefTile, x: Int, y: Int) -> Float {
        var bits: UInt16 = 0
        terrain.texture.getBytes(&bits, bytesPerRow: 2, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return GroundReliefTile.float(halfBits: bits)
    }

    // MARK: - The frame's demand

    /// One slot: the tiles load one after another in the order the frame
    /// wants them, nearest first, and a lookup never starts one.
    func testTheLoadsTakeTheDemandsOrderAndItsLimit() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 0, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true,
                                                                              minimumSourceZoom: 12,
                                                                              maximumConcurrentLoads: 1)
        let order = Locked<[String]>([])
        let ground = makeTestRelief(device: device, settings: settings, fetch: { url in
            order.withLock { $0.append(url.path) }
            return .image(image)
        })
        let tiles = [Tile(x: 2412, y: 3080, z: 13), Tile(x: 2413, y: 3080, z: 13), Tile(x: 2412, y: 3081, z: 13)]
        _ = ground.frame.relief(for: tiles[0], terrainZoom: 13)
        XCTAssertEqual(ground.frame.statusSnapshot().loadingCount, 0, "A lookup starts no load")
        ground.store.request(tiles: tiles)
        XCTAssertEqual(ground.frame.statusSnapshot().loadingCount, 1, "One slot")
        XCTAssertTrue(waitUntil { ground.frame.statusSnapshot().wantedResidentCount == 3 })
        XCTAssertEqual(order.withLock { $0 }, tiles.map { "/\($0.z)/\($0.x)/\($0.y).webp" })
    }

    /// A tile the source does not have is wanted as its ancestor, down to
    /// the source's floor.
    func testAMissingTileIsWantedAsItsParent() throws {
        let device = try Self.device()
        let image = try Self.png(size: 2, pixels: Array(repeating: (128, 0, 0), count: 4))
        let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true,
                                                                              tileURLTemplate: "https://terrain.example/{z}/{x}/{y}.png",
                                                                              minimumSourceZoom: 12)
        let ground = makeTestRelief(device: device, settings: settings, fetch: { url in
            url.absoluteString.contains("/15/") ? .missing : .image(image)
        })
        let tile = Tile(x: 9647, y: 12321, z: 15)
        let parent = try XCTUnwrap(tile.findParentTile(atZoom: 14))
        XCTAssertTrue(waitUntil {
            ground.store.request(tiles: [tile])
            return ground.frame.statusSnapshot().tiles.first == .init(tile: parent, state: .resident, priority: 0,
                                                               bytes: ground.frame.statusSnapshot().tiles.first?.bytes ?? 0,
                                                               heightRange: 0 ... 0, seconds: 0, attempts: 0)
        })
        XCTAssertEqual(ground.frame.statusSnapshot().missingCount, 1)
    }

    /// The relief tab's cards say what each terrain tile is doing.
    func testTheReliefCardsTellEachTilesState() {
        let snapshot = GroundReliefStatusSnapshot(
            tiles: [.init(tile: Tile(x: 1, y: 2, z: 12), state: .resident, priority: 0, bytes: 1_048_576,
                          heightRange: 100 ... 2300, seconds: 0, attempts: 0),
                    .init(tile: Tile(x: 2, y: 2, z: 12), state: .loading, priority: 1, bytes: 0,
                          heightRange: nil, seconds: 3, attempts: 0),
                    .init(tile: Tile(x: 3, y: 2, z: 12), state: .failed, priority: 2, bytes: 0,
                          heightRange: nil, seconds: 8, attempts: 2),
                    .init(tile: Tile(x: 4, y: 2, z: 11), state: .resident, priority: nil, bytes: 1_048_576,
                          heightRange: 0 ... 10, seconds: 0, attempts: 0)],
            isActive: true, standingShare: 1, datumMetres: 0, cameraTerrainZoom: 12, terrainByRing: "z12→z12",
            wantedCount: 3, wantedResidentCount: 1, residentCount: 2, residentBytes: 2_097_152,
            releasedCount: 1, releasedBytes: 1_048_576, releasedCacheBytes: 50 << 20,
            occlusionComputedCount: 2, occlusionMillisecondsLast: 3.25,
            loadingCount: 1, maximumConcurrentLoads: 4, failedCount: 1, missingCount: 0)
        let cards = DebugOverlayTileCard.reliefCards(for: snapshot)
        XCTAssertEqual(cards.map(\.headline), ["z12/1/2 in 1.0 MB", "z12/2/2 loading 3s",
                                               "z12/3/2 failed ×2 retry 8s", "z11/4/2 in 1.0 MB"])
        XCTAssertEqual(cards.map(\.stagesText), ["wanted #1", "wanted #2", "wanted #3", "kept"])
        XCTAssertEqual(cards.map(\.status), [.ready, .loading, .failed, .ready])
        XCTAssertEqual(snapshot.stateLines.count, 3)
        XCTAssertEqual(snapshot.loadingLines.count, 5)
        XCTAssertEqual(snapshot.memoryLines.count, 4)
        XCTAssertEqual(snapshot.memoryLines[1], "released 1 tiles, 1.0 of 50.0 MB")
        XCTAssertEqual(snapshot.occlusionLines, ["computed 2 of 2 tiles", "last tile 3.2 ms"])
        XCTAssertEqual(snapshot.surroundingsLines, ["around: waiting for terrain"])
        XCTAssertEqual(snapshot.lines.count, 13)
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    // MARK: - Helpers

    /// Asks for the tile's terrain, as a frame does, until some terrain
    /// over the tile is in. The store keeps what a frame asks for and no
    /// more, so every tile asked of a store so far is asked again: a test's
    /// frames want all of them.
    private var requestedTiles: [ObjectIdentifier: [Tile]] = [:]
    private func waitForRelief(of tile: Tile, in ground: GroundReliefFrameState) -> GroundRelief? {
        var tiles = requestedTiles[ObjectIdentifier(ground)] ?? []
        if tiles.contains(tile) == false { tiles.append(tile) }
        requestedTiles[ObjectIdentifier(ground)] = tiles
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            ground.store.request(tiles: tiles)
            if let relief = ground.frame.relief(for: tile, terrainZoom: tile.z) {
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

/// A relief over a terrain store whose tiles come from `fetch`, as the
/// map makes one (`GroundReliefFrameState.make`), with the URL source's
/// bytes and the clock the tests' own.
func makeTestRelief(device: MTLDevice,
                    settings: ImmersiveMapSettings.TileSettings.GroundReliefSettings,
                    deepestTileZoom: Int = ImmersiveMapSettings.default.tiles.coverage.maximumZoomLevel,
                    hillshade: ImmersiveMapHillshade = ImmersiveMapHillshade(),
                    occlusion: ImmersiveMapTerrainOcclusion = ImmersiveMapTerrainOcclusion(),
                    fetch: @escaping @Sendable (URL) async throws -> GroundReliefURLTerrainSource.Fetched,
                    now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) -> GroundReliefFrameState {
    let store = GroundReliefStore(device: device,
                                  settings: settings,
                                  source: GroundReliefURLTerrainSource(settings: settings, fetch: fetch),
                                  occlusionKey: GroundReliefOcclusion.Key(style: occlusion),
                                  now: now)
    return GroundReliefFrameState(store: store,
                                  settings: settings,
                                  deepestTileZoom: deepestTileZoom,
                                  hillshade: hillshade,
                                  occlusion: occlusion)
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import simd
import XCTest

/// The trees the data maps at points (`TreePointStyle`): each stands where
/// it is mapped, the scattered trees of a park keep off its crown, and the
/// built-in style plants one at every point of the basemap's `pois` of
/// kind `tree`.
final class TreePointTests: XCTestCase {
    private let tile = Tile(x: 19809, y: 10244, z: 15)
    private let mappedStyle = TreePointStyle(heightMetres: 7 ... 12, crownClearanceMetres: 4)
    private let parkStyle = TreeFillStyle(spacingMetres: 3, heightMetres: 6 ... 10, roadClearanceMetres: 0)

    private var wholeTile: Mvt.Polygon {
        let extent = Int32(TileCoordinateSpace.tileExtentInt)
        return Mvt.Polygon(exteriorRing: [Mvt.Point(x: 0, y: 0), Mvt.Point(x: extent, y: 0),
                                          Mvt.Point(x: extent, y: extent), Mvt.Point(x: 0, y: extent)],
                           interiorRings: [])
    }

    /// Tile units of the tile per metre, as the scatter reads them.
    private var unitsPerMetre: Float {
        let latitudeTile = tile.findParentTile(atZoom: TreeScatter.latitudeZoom) ?? tile
        let latitude = ImmersiveMapProjection.latitude(
            fromNormalizedWorldY: (Double(latitudeTile.y) + 0.5) / Double(1 << latitudeTile.z))
        return Float(TileCoordinateSpace.tileExtentDouble * pow(2.0, Double(tile.z))
            / (ImmersiveMapProjection.earthCircumferenceMeters * cos(latitude)))
    }

    func testAMappedTreeStandsWhereItIsMapped() {
        let point = SIMD2<Float>(1000, 2000)
        let trees = TreeScatter.scatter(areas: [],
                                        mapped: [TreeScatter.MappedTree(tilePoint: point, style: mappedStyle)],
                                        tile: tile,
                                        obstacles: TreeScatter.Obstacles(),
                                        maximumCount: 10)
        XCTAssertEqual(trees.count, 1, "a tile with mapped trees alone plants them")
        let tree = try? XCTUnwrap(trees.first)
        XCTAssertEqual(tree?.position, TileCoordinateSpace.renderPoint(point))
        let metres = (tree?.height ?? 0) / unitsPerMetre
        XCTAssertGreaterThanOrEqual(metres, 7 - 1e-3)
        XCTAssertLessThanOrEqual(metres, 12 + 1e-3)

        let again = TreeScatter.scatter(areas: [],
                                        mapped: [TreeScatter.MappedTree(tilePoint: point, style: mappedStyle)],
                                        tile: tile,
                                        obstacles: TreeScatter.Obstacles(),
                                        maximumCount: 10)
        XCTAssertEqual(again, trees, "the same tree at every parse")
    }

    /// A park's close lattice around a mapped tree: no scattered tree within
    /// its crown, and the rest of the park as it was.
    func testTheScatteredTreesKeepOffAMappedTreesCrown() {
        let point = SIMD2<Float>(2048, 2048)
        let park = TreeScatter.Area(polygons: [wholeTile], style: parkStyle)
        let without = TreeScatter.scatter(areas: [park], tile: tile, obstacles: TreeScatter.Obstacles(), maximumCount: 100_000)
        let with = TreeScatter.scatter(areas: [park],
                                       mapped: [TreeScatter.MappedTree(tilePoint: point, style: mappedStyle)],
                                       tile: tile,
                                       obstacles: TreeScatter.Obstacles(),
                                       maximumCount: 100_000)
        let centre = TileCoordinateSpace.renderPoint(point)
        let crown = mappedStyle.crownClearanceMetres * unitsPerMetre
        let mapped = with.filter { $0.position == centre }
        XCTAssertEqual(mapped.count, 1)
        let scatteredNear = with.filter { $0.position != centre && simd_distance($0.position, centre) < crown }
        XCTAssertEqual(scatteredNear.count, 0, "no scattered tree within the mapped tree's crown")
        let cleared = without.filter { simd_distance($0.position, centre) < crown }
        XCTAssertGreaterThan(cleared.count, 0, "the lattice is close enough to put trees there without the mapped one")
        XCTAssertEqual(with.count, without.count - cleared.count + 1)
    }

    /// The built-in style, through the whole parse: a `pois` point of kind
    /// `tree` stands a tree at its point, and is no label.
    func testTheBuiltInStylePlantsATreeAtATreePoint() throws {
        let data = VectorTileFixture.layerTile(
            layerName: "pois",
            features: [VectorTileFixture.Feature.poi(id: 1, at: (1024, 3072), kind: "tree", name: "", minZoom: 16)])
        let parser = TileMvtParser.forTests(settings: ImmersiveMapSettings.defaultWithoutRelief)
        let parsed = try parser.parse(tile: tile, mvtData: data)
        XCTAssertEqual(parsed.trees.map(\.position), [TileCoordinateSpace.renderPoint(SIMD2<Float>(1024, 3072))])
        XCTAssertTrue(parsed.textLabels.isEmpty, "a mapped tree is not named")
        XCTAssertEqual(ProtomapsBasemapTheme.default.layers.trees.mapped, mappedStyle)
    }
}

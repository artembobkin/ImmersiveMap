// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class ImmersiveMapGeoJSONTests: XCTestCase {
    private func layer(_ json: String,
                       polygonStyle: ImmersiveMapPolygonStyle = ImmersiveMapPolygonStyle()) throws -> ImmersiveMapLayer {
        try ImmersiveMapLayer(id: "test", geoJSON: Data(json.utf8), polygonStyle: polygonStyle)
    }

    /// Every geometry type lands as its kind of shape, the positions read
    /// as longitude then latitude, an altitude ignored, a null geometry
    /// skipped.
    func testAFeatureCollectionReadsEveryGeometryType() throws {
        let json = """
        {"type": "FeatureCollection", "features": [
          {"type": "Feature", "properties": {}, "geometry": {"type": "Point", "coordinates": [37.6, 55.7, 120]}},
          {"type": "Feature", "properties": null, "geometry": {"type": "MultiPoint", "coordinates": [[1, 2], [3, 4]]}},
          {"type": "Feature", "geometry": {"type": "LineString", "coordinates": [[0, 0], [1, 1]]}},
          {"type": "Feature", "geometry": {"type": "MultiLineString", "coordinates": [[[0, 0], [1, 1]], [[2, 2], [3, 3]]]}},
          {"type": "Feature", "geometry": {"type": "Polygon", "coordinates": [
              [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
              [[2, 2], [4, 2], [4, 4], [2, 2]]]}},
          {"type": "Feature", "geometry": {"type": "MultiPolygon", "coordinates": [
              [[[20, 20], [21, 20], [21, 21], [20, 20]]],
              [[[30, 30], [31, 30], [31, 31], [30, 30]]]]}},
          {"type": "Feature", "geometry": null},
          {"type": "Feature", "geometry": {"type": "GeometryCollection", "geometries": [
              {"type": "Point", "coordinates": [5, 6]}]}}
        ]}
        """
        let layer = try layer(json)
        XCTAssertEqual(layer.points.count, 4)
        XCTAssertEqual(layer.points[0].coordinate, GeoCoordinate(latitude: 55.7, longitude: 37.6))
        XCTAssertEqual(layer.polylines.count, 3)
        XCTAssertEqual(layer.polygons.count, 3)
        XCTAssertEqual(layer.polygons[0].exterior.count, 5)
        XCTAssertEqual(layer.polygons[0].holes.count, 1)
        XCTAssertNil(layer.polygons[0].style, "A feature that states no style takes the layer's")
    }

    /// A bare geometry is a document of its own.
    func testABareGeometryIsADocument() throws {
        let layer = try layer(#"{"type": "Polygon", "coordinates": [[[0, 0], [1, 0], [1, 1], [0, 0]]]}"#)
        XCTAssertEqual(layer.polygons.count, 1)
    }

    /// The simplestyle properties lay the feature's colours and widths over
    /// the layer's style, keeping the layer's for what they leave out.
    func testSimplestylePropertiesStyleAFeatureOverTheLayer() throws {
        let base = ImmersiveMapPolygonStyle(fillColor: SIMD4<Float>(0, 0, 1, 0.5),
                                            strokeColor: SIMD4<Float>(0, 1, 0, 1),
                                            strokeWidthPoints: 3)
        let json = """
        {"type": "Feature",
         "properties": {"fill": "#f00", "stroke-width": 5},
         "geometry": {"type": "Polygon", "coordinates": [[[0, 0], [1, 0], [1, 1], [0, 0]]]}}
        """
        let style = try XCTUnwrap(try layer(json, polygonStyle: base).polygons.first?.style)
        XCTAssertEqual(style.fillColor, SIMD4<Float>(1, 0, 0, 0.5), "The fill's colour is the feature's, its opacity the layer's")
        XCTAssertEqual(style.strokeColor, base.strokeColor)
        XCTAssertEqual(style.strokeWidthPoints, 5)
    }

    func testColoursReadInBothHexForms() {
        XCTAssertEqual(ImmersiveMapGeoJSON.color("#ff8000"), SIMD3<Float>(1, 128.0 / 255, 0))
        XCTAssertEqual(ImmersiveMapGeoJSON.color("0f0"), SIMD3<Float>(0, 1, 0))
        XCTAssertNil(ImmersiveMapGeoJSON.color("red"))
        XCTAssertNil(ImmersiveMapGeoJSON.color(42))
    }

    func testANonGeoJSONDocumentThrows() {
        XCTAssertThrowsError(try layer("not json")) { error in
            XCTAssertEqual(error as? ImmersiveMapGeoJSONError, .invalidJSON)
        }
        XCTAssertThrowsError(try layer(#"{"type": "Circle"}"#)) { error in
            XCTAssertEqual(error as? ImmersiveMapGeoJSONError, .unknownType("Circle"))
        }
        XCTAssertThrowsError(try layer(#"{"type": "Point", "coordinates": [1]}"#)) { error in
            XCTAssertEqual(error as? ImmersiveMapGeoJSONError, .invalidCoordinates("coordinates"))
        }
    }
}

final class ImmersiveMapLayerTests: XCTestCase {
    private let square = ImmersiveMapPolygon(exterior: [GeoCoordinate(latitude: 0, longitude: 0),
                                                        GeoCoordinate(latitude: 0, longitude: 10),
                                                        GeoCoordinate(latitude: 10, longitude: 10),
                                                        GeoCoordinate(latitude: 10, longitude: 0)])

    /// Two layers made from the same data are equal, so a view that makes
    /// its layers anew on every update changes nothing, and a change of a
    /// coordinate is a change.
    func testLayersCompareByTheirData() {
        let first = ImmersiveMapLayer(id: "zones", polygons: [square])
        let second = ImmersiveMapLayer(id: "zones", polygons: [square])
        XCTAssertEqual(first, second)

        var moved = square
        moved.exterior[0].latitude = 0.000001
        XCTAssertNotEqual(first, ImmersiveMapLayer(id: "zones", polygons: [moved]))

        var hidden = first
        hidden.isVisible = false
        XCTAssertNotEqual(first, hidden)
        XCTAssertEqual(first.meshKey, hidden.meshKey, "Hiding a layer does not build it again")

        var behindTerrain = first
        behindTerrain.hidesBehindTerrain = true
        XCTAssertNotEqual(first, behindTerrain)
        XCTAssertEqual(first.meshKey, behindTerrain.meshKey, "How the terrain hides a layer does not build it again")
    }

    /// A change of the layers applies live.
    func testAChangeOfTheLayersAppliesLive() {
        let settings = ImmersiveMapSettings.default
        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(
            from: settings,
            to: settings.layers([ImmersiveMapLayer(id: "zones", polygons: [square])]))
        XCTAssertEqual(plan.changedDomains, [.layers])
        XCTAssertEqual(plan.actions, [.liveApply])
    }

    /// The GPU structs match the shader's layouts byte for byte.
    func testTheVertexLayoutsMatchTheShaders() {
        XCTAssertEqual(MemoryLayout<LayerFillVertex>.stride, 16)
        XCTAssertEqual(MemoryLayout<LayerLineVertex>.stride, 32)
        XCTAssertEqual(MemoryLayout<LayerLineVertex>.offset(of: \.widthPoints), 24)
        XCTAssertEqual(MemoryLayout<LayerLineVertex>.offset(of: \.color), 28)
        XCTAssertEqual(MemoryLayout<LayerPointInstance>.stride, 24)
        XCTAssertEqual(MemoryLayout<LayerPointInstance>.offset(of: \.color), 16)
        XCTAssertEqual(MemoryLayout<LayerDrawUniform>.stride, 96)
    }
}

final class LayerMeshBuilderTests: XCTestCase {
    /// Every triangle of a zone is counter-clockwise in render space (y
    /// north), the front face the sphere's culling keeps, whichever way
    /// the ring runs.
    func testAZonesTrianglesAreCounterClockwiseWhicheverWayItsRingRuns() {
        let ring = [GeoCoordinate(latitude: 0, longitude: 0), GeoCoordinate(latitude: 0, longitude: 1),
                    GeoCoordinate(latitude: 1, longitude: 1), GeoCoordinate(latitude: 1, longitude: 0)]
        for exterior in [ring, ring.reversed()] {
            let data = LayerMeshBuilder.build(layer: ImmersiveMapLayer(id: "z", polygons: [ImmersiveMapPolygon(exterior: exterior)]))
            XCTAssertFalse(data.fillIndices.isEmpty)
            var start = 0
            while start + 2 < data.fillIndices.count {
                let a = data.fillVertices[Int(data.fillIndices[start])].position
                let b = data.fillVertices[Int(data.fillIndices[start + 1])].position
                let c = data.fillVertices[Int(data.fillIndices[start + 2])].position
                let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                XCTAssertGreaterThan(cross, 0)
                start += 3
            }
        }
    }

    /// A zone wider than the longest edge is cut into triangles that follow
    /// the sphere, and its outline into short segments.
    func testALargeZoneIsCutIntoShortEdges() {
        let ring = [GeoCoordinate(latitude: -20, longitude: -20), GeoCoordinate(latitude: -20, longitude: 20),
                    GeoCoordinate(latitude: 20, longitude: 20), GeoCoordinate(latitude: 20, longitude: -20)]
        let data = LayerMeshBuilder.build(layer: ImmersiveMapLayer(id: "z", polygons: [ImmersiveMapPolygon(exterior: ring)]))
        let chunk = try! XCTUnwrap(data.chunks.first)
        let unitsPerWorld = Float(1 << chunk.tile.z) * TileCoordinateSpace.tileExtent
        let longest = Float(LayerMeshBuilder.maximumEdgeLength) * unitsPerWorld * 1.0001
        var start = 0
        while start + 2 < data.fillIndices.count {
            let corners = (0 ..< 3).map { data.fillVertices[Int(data.fillIndices[start + $0])].position }
            for index in 0 ..< 3 {
                XCTAssertLessThanOrEqual(simd_distance(corners[index], corners[(index + 1) % 3]), longest)
            }
            start += 3
        }
        for vertex in data.lineVertices {
            XCTAssertLessThanOrEqual(simd_distance(vertex.start, vertex.end), longest)
        }
        // The outline's four corners are its joins.
        XCTAssertEqual(chunk.joinCount, 4)
    }

    /// A zone across the 180th meridian stays whole: its longitudes run on
    /// past 180, and its fill spans 20 degrees, not 340.
    func testAZoneAcrossTheAntimeridianStaysWhole() {
        let ring = [GeoCoordinate(latitude: 0, longitude: 170), GeoCoordinate(latitude: 0, longitude: -170),
                    GeoCoordinate(latitude: 10, longitude: -170), GeoCoordinate(latitude: 10, longitude: 170)]
        let data = LayerMeshBuilder.build(layer: ImmersiveMapLayer(id: "z", polygons: [ImmersiveMapPolygon(exterior: ring)]))
        let chunk = try! XCTUnwrap(data.chunks.first)
        let unitsPerWorld = Float(1 << chunk.tile.z) * TileCoordinateSpace.tileExtent
        let xs = data.fillVertices.map(\.position.x)
        let span = (xs.max()! - xs.min()!) / unitsPerWorld
        XCTAssertEqual(span, 20.0 / 360.0, accuracy: 1e-4)
    }

    /// Points are grouped by their chunk, each chunk's discs after every
    /// chunk's joins, and a point drawn in nothing (no size, no colour) is
    /// left out.
    func testPointsLandInTheirChunks() {
        let points = [ImmersiveMapPoint(coordinate: GeoCoordinate(latitude: 55.75, longitude: 37.6)),
                      ImmersiveMapPoint(coordinate: GeoCoordinate(latitude: 55.76, longitude: 37.61)),
                      ImmersiveMapPoint(coordinate: GeoCoordinate(latitude: -33.9, longitude: 151.2)),
                      ImmersiveMapPoint(coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                                        style: ImmersiveMapPointStyle(radiusPoints: 0, strokeWidthPoints: 0))]
        let data = LayerMeshBuilder.build(layer: ImmersiveMapLayer(id: "p", points: points))
        XCTAssertEqual(data.chunks.count, 2)
        XCTAssertEqual(data.chunks.map(\.pointCount).reduce(0, +), 3)
        XCTAssertEqual(data.discs.count, 3)
        // Each point lies in its chunk's square.
        for chunk in data.chunks {
            for disc in data.discs[chunk.pointStart ..< chunk.pointStart + chunk.pointCount] {
                XCTAssertTrue((0 ... TileCoordinateSpace.tileExtent).contains(disc.position.x))
                XCTAssertTrue((0 ... TileCoordinateSpace.tileExtent).contains(disc.position.y))
            }
        }
    }
}

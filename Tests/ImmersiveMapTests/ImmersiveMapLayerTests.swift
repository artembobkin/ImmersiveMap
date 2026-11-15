// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class ImmersiveMapGeoJSONTests: XCTestCase {
    private func layer(_ json: String) throws -> ImmersiveMapGeoJSON.Shapes {
        try ImmersiveMapGeoJSON.decode(Data(json.utf8))
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
        XCTAssertNil(layer.polygons[0].style)
        XCTAssertNil(layer.polygons[0].simpleStyle, "A feature that states no style takes the layer's")
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
        // The feature's part is kept with the shape and laid over whichever
        // layer draws it.
        let stated = try XCTUnwrap(try layer(json).polygons.first?.simpleStyle)
        let style = try XCTUnwrap(ImmersiveMapGeoJSON.polygonStyle(stated, base: base))
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

    /// A layer is a small value compared by what it states, and only its
    /// source and styles are baked into its mesh.
    func testALayersMeshDependsOnItsSourceAndStylesAlone() {
        let first = ImmersiveMapLayer(source: "zones")
        XCTAssertEqual(first, ImmersiveMapLayer(source: "zones"))
        XCTAssertEqual(first.id, "zones", "A layer goes by its source's name unless it is given an id")
        XCTAssertEqual(ImmersiveMapLayer(id: "outline", source: "zones").id, "outline")

        var hidden = first
        hidden.isVisible = false
        XCTAssertNotEqual(first, hidden)
        XCTAssertEqual(first.meshKey(sourceRevision: 1), hidden.meshKey(sourceRevision: 1),
                       "Hiding a layer does not build it again")

        var behindTerrain = first
        behindTerrain.hidesBehindTerrain = true
        XCTAssertEqual(first.meshKey(sourceRevision: 1), behindTerrain.meshKey(sourceRevision: 1),
                       "How the terrain hides a layer does not build it again")

        var restyled = first
        restyled.polygonStyle.strokeWidthPoints = 9
        XCTAssertNotEqual(first.meshKey(sourceRevision: 1), restyled.meshKey(sourceRevision: 1))
        XCTAssertNotEqual(first.meshKey(sourceRevision: 1), first.meshKey(sourceRevision: 2),
                          "A source registered with other data builds its layers again")
    }

    // MARK: - The controller

    private func layer(_ id: String, isVisible: Bool = true) -> ImmersiveMapLayer {
        ImmersiveMapLayer(id: id, source: "squares", isVisible: isVisible)
    }

    /// The controller keeps the layers in the order they draw, one to an id.
    func testTheControllerKeepsTheOrderAndOneLayerToAnId() {
        let controller = ImmersiveMapLayersController([layer("a"), layer("b")])
        XCTAssertEqual(controller.layers.map(\.id), ["a", "b"])

        controller.upsert(layer("c"))
        controller.upsert(layer("a", isVisible: false))
        XCTAssertEqual(controller.layers.map(\.id), ["a", "b", "c"], "A layer set again keeps its place")
        XCTAssertEqual(controller.layer(id: "a")?.isVisible, false)

        controller.remove(id: "b")
        XCTAssertEqual(controller.layers.map(\.id), ["a", "c"])
        XCTAssertNil(controller.layer(id: "b"))

        controller.set([layer("x"), layer("y"), layer("x", isVisible: false)])
        XCTAssertEqual(controller.layers.map(\.id), ["x", "y"], "The last layer given under an id, in the place of the first")
        XCTAssertEqual(controller.layer(id: "x")?.isVisible, false)

        controller.setVisible(id: "x", true)
        XCTAssertEqual(controller.layer(id: "x")?.isVisible, true)

        controller.clear()
        XCTAssertTrue(controller.layers.isEmpty)
    }

    /// The map is told of a change, and of nothing when the layers are set
    /// to what they are.
    func testTheControllerTellsTheMapOfAChangeAlone() {
        let controller = ImmersiveMapLayersController()
        let owner = NSObject()
        var changes = 0
        controller.setChangeHandler({ changes += 1 }, owner: owner)

        controller.set([layer("a")])
        XCTAssertEqual(changes, 1)
        controller.set([layer("a")])
        controller.upsert(layer("a"))
        controller.setVisible(id: "a", true)
        controller.remove(id: "missing")
        XCTAssertEqual(changes, 1, "The same layers again ask for no frame")

        controller.setVisible(id: "a", false)
        XCTAssertEqual(changes, 2)

        // A stale owner's detach leaves the handler of the one that holds it.
        controller.clearChangeHandler(ownedBy: NSObject())
        controller.clear()
        XCTAssertEqual(changes, 3)
        controller.clearChangeHandler(ownedBy: owner)
        controller.set([layer("b")])
        XCTAssertEqual(changes, 3)
    }

    /// A fixed source hands the frames the layers it was made with.
    func testAFixedSourceHoldsItsLayers() {
        XCTAssertTrue(FixedLayerRenderSource().currentLayers.isEmpty)
        XCTAssertNil(FixedLayerRenderSource().sourceLibrary)
        let controller = ImmersiveMapLayersController([layer("a")])
        let source = FixedLayerRenderSource(controller)
        controller.set([layer("b")])
        XCTAssertEqual(source.currentLayers.map(\.id), ["a"], "The layers are the controller's as they were")
        XCTAssertTrue(source.sourceLibrary === controller.library)
    }

    /// The GPU structs match the shader's layouts byte for byte.
    func testTheVertexLayoutsMatchTheShaders() {
        XCTAssertEqual(MemoryLayout<LayerFillVertex>.stride, 16)
        XCTAssertEqual(MemoryLayout<LayerLineSegment>.stride, 24)
        XCTAssertEqual(MemoryLayout<LayerLineSegment>.offset(of: \.widthPoints), 16)
        XCTAssertEqual(MemoryLayout<LayerLineSegment>.offset(of: \.color), 20)
        XCTAssertEqual(MemoryLayout<LayerPointInstance>.stride, 24)
        XCTAssertEqual(MemoryLayout<LayerPointInstance>.offset(of: \.color), 16)
        XCTAssertEqual(MemoryLayout<LayerDrawUniform>.stride, 96)
    }
}

final class LayerMeshBuilderTests: XCTestCase {
    /// The mesh of a layer drawing the shapes given, in the default styles.
    private static func build(polygons: [ImmersiveMapPolygon] = [],
                              points: [ImmersiveMapPoint] = []) -> LayerMeshData {
        LayerMeshBuilder.build(layer: ImmersiveMapLayer(source: "shapes"),
                               content: LayerSourceContent(polygons: polygons, polylines: [], points: points))
    }

    /// Every triangle of a zone is counter-clockwise in render space (y
    /// north), the front face the sphere's culling keeps, whichever way
    /// the ring runs.
    func testAZonesTrianglesAreCounterClockwiseWhicheverWayItsRingRuns() {
        let ring = [GeoCoordinate(latitude: 0, longitude: 0), GeoCoordinate(latitude: 0, longitude: 1),
                    GeoCoordinate(latitude: 1, longitude: 1), GeoCoordinate(latitude: 1, longitude: 0)]
        for exterior in [ring, ring.reversed()] {
            let data = Self.build(polygons: [ImmersiveMapPolygon(exterior: exterior)])
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
        let data = Self.build(polygons: [ImmersiveMapPolygon(exterior: ring)])
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
        for vertex in data.lineSegments {
            XCTAssertLessThanOrEqual(simd_distance(vertex.start, vertex.end), longest)
        }
        // The outline is round at its four corners alone, and flat where a
        // side was only cut to follow the sphere. A join has no disc.
        XCTAssertEqual(chunk.joinCount, 0)
        let rounding = data.lineSegments.map(\.color.w)
        XCTAssertEqual(chunk.lineCount, rounding.count)
        XCTAssertGreaterThan(rounding.count, 4, "Each side is cut into pieces")
        XCTAssertEqual(rounding.count { $0 == LayerLineSegment.roundStart }, 4)
        XCTAssertEqual(rounding.count { $0 == LayerLineSegment.roundEnd }, 4)
        XCTAssertEqual(rounding.count { $0 == 0 }, rounding.count - 8, "A piece in the middle of a side is flat at both ends")
    }

    /// A line is always solid: a translucent colour draws it opaque, and
    /// only a zero alpha leaves it out. The fill keeps its alpha.
    func testALineIsSolidWhateverItsColoursAlpha() {
        let ring = [GeoCoordinate(latitude: 0, longitude: 0), GeoCoordinate(latitude: 0, longitude: 1),
                    GeoCoordinate(latitude: 1, longitude: 1), GeoCoordinate(latitude: 1, longitude: 0)]
        let content = LayerSourceContent(polygons: [ImmersiveMapPolygon(exterior: ring)],
                                         polylines: [ImmersiveMapPolyline(coordinates: ring)],
                                         points: [])
        func mesh(lineAlpha: Float) -> LayerMeshData {
            let layer = ImmersiveMapLayer(source: "shapes",
                                          polygonStyle: ImmersiveMapPolygonStyle(fillColor: SIMD4(1, 0, 0, 0.5),
                                                                                 strokeColor: SIMD4(0, 1, 0, lineAlpha)),
                                          polylineStyle: ImmersiveMapPolylineStyle(color: SIMD4(0, 0, 1, lineAlpha)))
            return LayerMeshBuilder.build(layer: layer, content: content)
        }

        // The fourth byte of a segment's colour is not an alpha: it says
        // which of its ends are round, and the line draws without blending.
        let translucent = mesh(lineAlpha: 0.25)
        XCTAssertFalse(translucent.lineSegments.isEmpty)
        XCTAssertEqual(translucent.lineSegments, mesh(lineAlpha: 1).lineSegments, "The alpha changes nothing of a line")
        XCTAssertTrue(translucent.lineSegments.allSatisfy { $0.color.w == LayerLineSegment.roundStart | LayerLineSegment.roundEnd })
        XCTAssertTrue(translucent.discs.isEmpty, "A join is the round ends of its segments, not a disc")
        XCTAssertTrue(translucent.fillVertices.allSatisfy { $0.color.w == 128 }, "A fill may be translucent")

        let hidden = mesh(lineAlpha: 0)
        XCTAssertTrue(hidden.lineSegments.isEmpty)
        XCTAssertTrue(hidden.discs.isEmpty)
    }

    /// The triangles of a segment's shape name its ten corners alone.
    func testASegmentsTemplateDrawsItsTenCorners() {
        XCTAssertEqual(LayerPipeline.lineTemplate.count % 3, 0)
        XCTAssertEqual(Set(LayerPipeline.lineTemplate), Set(0 ..< 10))
    }

    /// A zone across the 180th meridian stays whole: its longitudes run on
    /// past 180, and its fill spans 20 degrees, not 340.
    func testAZoneAcrossTheAntimeridianStaysWhole() {
        let ring = [GeoCoordinate(latitude: 0, longitude: 170), GeoCoordinate(latitude: 0, longitude: -170),
                    GeoCoordinate(latitude: 10, longitude: -170), GeoCoordinate(latitude: 10, longitude: 170)]
        let data = Self.build(polygons: [ImmersiveMapPolygon(exterior: ring)])
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
        let data = Self.build(points: points)
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

final class LayerChunkCullingTests: XCTestCase {
    private let viewport = SIMD2<Float>(1000, 1000)

    private func isVisible(minimum: SIMD2<Float>, maximum: SIMD2<Float>,
                           matrix: matrix_float4x4 = matrix_identity_float4x4,
                           reachPx: Float = 0) -> Bool {
        LayerChunkCulling.isVisible(boundsMinimum: minimum, boundsMaximum: maximum,
                                    clipFromLocal: matrix, reachPx: reachPx, viewportSizePx: viewport)
    }

    /// Under the identity matrix the view is the square from -1 to 1.
    func testABoxInsideOrAcrossTheViewIsDrawn() {
        XCTAssertTrue(isVisible(minimum: SIMD2(-0.5, -0.5), maximum: SIMD2(0.5, 0.5)))
        XCTAssertTrue(isVisible(minimum: SIMD2(0.9, 0.9), maximum: SIMD2(3, 3)))
        // Round the whole view, every corner outside it.
        XCTAssertTrue(isVisible(minimum: SIMD2(-5, -5), maximum: SIMD2(5, 5)))
    }

    func testABoxBeyondOneEdgeIsLeftOut() {
        XCTAssertFalse(isVisible(minimum: SIMD2(1.5, -0.5), maximum: SIMD2(2, 0.5)))
        XCTAssertFalse(isVisible(minimum: SIMD2(-2, -0.5), maximum: SIMD2(-1.5, 0.5)))
        XCTAssertFalse(isVisible(minimum: SIMD2(-0.5, 1.5), maximum: SIMD2(0.5, 2)))
        XCTAssertFalse(isVisible(minimum: SIMD2(-0.5, -2), maximum: SIMD2(0.5, -1.5)))
    }

    /// A line 100 pixels wide reaches 50 pixels past its position, a tenth
    /// of the view's half width here.
    func testAShapesReachOnScreenKeepsItsChunk() {
        let minimum = SIMD2<Float>(1.05, -0.5)
        let maximum = SIMD2<Float>(1.2, 0.5)
        XCTAssertFalse(isVisible(minimum: minimum, maximum: maximum))
        XCTAssertTrue(isVisible(minimum: minimum, maximum: maximum, reachPx: 50))
    }

    func testABoxBehindTheCameraIsLeftOut() {
        var behind = matrix_identity_float4x4
        behind.columns.3.w = -1
        XCTAssertFalse(isVisible(minimum: SIMD2(-0.5, -0.5), maximum: SIMD2(0.5, 0.5), matrix: behind))
    }

    /// A chunk with no position has no box to test, and is not left out.
    func testAnEmptyBoxIsDrawn() {
        XCTAssertTrue(isVisible(minimum: SIMD2(repeating: .infinity), maximum: SIMD2(repeating: -.infinity)))
    }

    /// The chunk's box holds every position of its fills, lines and points,
    /// and its reach is the widest of what they add on screen.
    func testAChunkKnowsItsBoundsAndItsReach() {
        let ring = [GeoCoordinate(latitude: 55.7, longitude: 37.5), GeoCoordinate(latitude: 55.7, longitude: 37.7),
                    GeoCoordinate(latitude: 55.8, longitude: 37.7), GeoCoordinate(latitude: 55.8, longitude: 37.5)]
        let layer = ImmersiveMapLayer(source: "z",
                                      polygonStyle: ImmersiveMapPolygonStyle(strokeWidthPoints: 6),
                                      pointStyle: ImmersiveMapPointStyle(radiusPoints: 10, strokeWidthPoints: 2))
        let content = LayerSourceContent(polygons: [ImmersiveMapPolygon(exterior: ring)],
                                         polylines: [],
                                         points: [ImmersiveMapPoint(coordinate: GeoCoordinate(latitude: 55.75, longitude: 37.6))])
        let data = LayerMeshBuilder.build(layer: layer, content: content)
        XCTAssertEqual(data.chunks.count, 1)
        let chunk = try! XCTUnwrap(data.chunks.first)
        for position in data.fillVertices.map(\.position) + data.lineSegments.flatMap({ [$0.start, $0.end] })
            + data.discs.map(\.position) {
            XCTAssertTrue((chunk.boundsMinimum.x ... chunk.boundsMaximum.x).contains(position.x))
            XCTAssertTrue((chunk.boundsMinimum.y ... chunk.boundsMaximum.y).contains(position.y))
        }
        XCTAssertLessThan(chunk.boundsMinimum.x, chunk.boundsMaximum.x)
        XCTAssertEqual(chunk.maximumReachPoints, 12)
    }
}

// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// A tap on the layers of the app's data: the place under it, and the shape
/// of the drawn layers at that place.
final class LayerPickMathTests: XCTestCase {
    /// A flat map seen straight down: 1000 pixels to a world unit, y up.
    private static func straightDown(_ world: SIMD2<Double>) -> SIMD2<Double>? {
        SIMD2(world.x * 1000, (1 - world.y) * 1000)
    }

    /// A tilted camera: the scale falls toward the north, and nothing shows
    /// past the horizon at y = 0.1.
    private static func tilted(_ world: SIMD2<Double>) -> SIMD2<Double>? {
        let depth = world.y - 0.1
        guard depth > 0 else { return nil }
        return SIMD2(500 + (world.x - 0.5) * 400 / depth, 300 / depth)
    }

    func testThePlaceUnderAPixelIsFoundOnAFlatMap() throws {
        let place = try XCTUnwrap(LayerPickMath.place(under: SIMD2(250, 600),
                                                      start: SIMD2(0.9, 0.9),
                                                      project: Self.straightDown))
        XCTAssertEqual(place.world.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(place.world.y, 0.4, accuracy: 1e-6)
        XCTAssertEqual(simd_length(place.pixelOffset(to: place.world + SIMD2(0.001, 0))), 1, accuracy: 1e-6,
                       "A thousandth of the world is a pixel here")
    }

    func testThePlaceIsFoundUnderATiltedCameraFromFarAway() throws {
        let target = SIMD2<Double>(0.42, 0.15)
        let pixel = try XCTUnwrap(Self.tilted(target))
        let place = try XCTUnwrap(LayerPickMath.place(under: pixel, start: SIMD2(0.5, 0.9), project: Self.tilted))
        // Within the quarter of a pixel the search stops at.
        XCTAssertEqual(place.world.x, target.x, accuracy: 1e-4)
        XCTAssertEqual(place.world.y, target.y, accuracy: 1e-5)
    }

    func testAPixelOffTheMapHasNoPlace() {
        // Nothing projects below the horizon's row of pixels.
        XCTAssertNil(LayerPickMath.place(under: SIMD2(500, -50), start: SIMD2(0.5, 0.5), project: Self.tilted))
    }

    func testAWorldPositionIsItsCoordinate() {
        let world = LayerMeshBuilder.world(GeoCoordinate(latitude: 55.75, longitude: 37.6))
        let coordinate = LayerPickMath.coordinate(ofWorld: world)
        XCTAssertEqual(coordinate.latitude, 55.75, accuracy: 1e-9)
        XCTAssertEqual(coordinate.longitude, 37.6, accuracy: 1e-9)
    }

    func testARingHoldsWhatIsInsideIt() {
        let ring = [SIMD2<Double>(0, 0), SIMD2(2, 0), SIMD2(2, 2), SIMD2(0, 2)]
        XCTAssertTrue(LayerPickMath.ring(ring, contains: SIMD2(1, 1)))
        XCTAssertFalse(LayerPickMath.ring(ring, contains: SIMD2(3, 1)))
        XCTAssertEqual(LayerPickMath.distanceFromOrigin(toSegment: SIMD2(-1, 2), SIMD2(1, 2)), 2, accuracy: 1e-12)
        XCTAssertEqual(LayerPickMath.distanceFromOrigin(toSegment: SIMD2(3, 4), SIMD2(6, 8)), 5, accuracy: 1e-12,
                       "Past the segment's end, its end is the nearest")
    }
}

final class LayerSelectionSnapshotTests: XCTestCase {
    /// The place of a coordinate on a map of `pixelsPerDegree` at the
    /// equator, seen straight down.
    private static func place(latitude: Double, longitude: Double, pixelsPerDegree: Double = 100) -> LayerPickMath.Place {
        let scale = pixelsPerDegree * 360
        return LayerPickMath.Place(world: LayerMeshBuilder.world(GeoCoordinate(latitude: latitude, longitude: longitude)),
                                   pixelsPerWorld: simd_double2x2(diagonal: SIMD2(scale, -scale)))
    }

    private static func entry(_ layer: ImmersiveMapLayer,
                              polygons: [ImmersiveMapPolygon] = [],
                              polylines: [ImmersiveMapPolyline] = [],
                              points: [ImmersiveMapPoint] = []) -> LayerSelectionSnapshot.Entry {
        LayerSelectionSnapshot.Entry(layer: layer,
                                     content: LayerSourceContent(polygons: polygons, polylines: polylines, points: points))
    }

    private static func square(id: UInt64? = nil, from minimum: Double, to maximum: Double,
                               holes: [[GeoCoordinate]] = []) -> ImmersiveMapPolygon {
        ImmersiveMapPolygon(id: id,
                            exterior: [GeoCoordinate(latitude: minimum, longitude: minimum),
                                       GeoCoordinate(latitude: minimum, longitude: maximum),
                                       GeoCoordinate(latitude: maximum, longitude: maximum),
                                       GeoCoordinate(latitude: maximum, longitude: minimum)],
                            holes: holes)
    }

    private func hit(_ entries: [LayerSelectionSnapshot.Entry], latitude: Double, longitude: Double) -> LayerSelectionHit? {
        LayerSelectionSnapshot.hit(in: entries, at: Self.place(latitude: latitude, longitude: longitude), pixelsPerPoint: 1)
    }

    func testAZoneIsHitInItsFillAndNotInItsHole() {
        let hole = [GeoCoordinate(latitude: 4, longitude: 4), GeoCoordinate(latitude: 4, longitude: 6),
                    GeoCoordinate(latitude: 6, longitude: 6), GeoCoordinate(latitude: 6, longitude: 4)]
        let entries = [Self.entry(ImmersiveMapLayer(source: "zones"),
                                  polygons: [Self.square(id: 7, from: 0, to: 10, holes: [hole])])]

        let inside = hit(entries, latitude: 2, longitude: 2)
        XCTAssertEqual(inside?.layerID, "zones")
        XCTAssertEqual(inside?.shapeID, 7)
        XCTAssertEqual(inside?.coordinate.latitude ?? 0, 2, accuracy: 1e-9)
        XCTAssertNil(hit(entries, latitude: 5, longitude: 5), "A hole is not the zone")
        XCTAssertNil(hit(entries, latitude: 20, longitude: 2))
    }

    func testAZoneWithNoFillIsHitOnItsOutlineAlone() {
        let outline = ImmersiveMapLayer(source: "zones",
                                        polygonStyle: ImmersiveMapPolygonStyle(fillColor: SIMD4(0, 0, 0, 0)))
        let entries = [Self.entry(outline, polygons: [Self.square(from: 0, to: 10)])]

        XCTAssertNil(hit(entries, latitude: 5, longitude: 5), "A tap inside goes through to the map")
        XCTAssertNotNil(hit(entries, latitude: 5, longitude: 0.03), "Three pixels off the edge is within reach")
        XCTAssertNil(hit(entries, latitude: 5, longitude: 0.5), "Fifty pixels off is not")
    }

    func testTheNearestPointWinsAndCoversTheZoneUnderIt() {
        let points = [ImmersiveMapPoint(id: 1, coordinate: GeoCoordinate(latitude: 5, longitude: 5)),
                      ImmersiveMapPoint(id: 2, coordinate: GeoCoordinate(latitude: 5, longitude: 5.1))]
        let entries = [Self.entry(ImmersiveMapLayer(source: "mixed"),
                                  polygons: [Self.square(id: 9, from: 0, to: 10)],
                                  points: points)]

        XCTAssertEqual(hit(entries, latitude: 5, longitude: 5.08)?.shapeID, 2, "Two pixels from the second, eight from the first")
        XCTAssertEqual(hit(entries, latitude: 5, longitude: 5.02)?.shapeID, 1)
        XCTAssertEqual(hit(entries, latitude: 8, longitude: 8)?.shapeID, 9, "Away from the points, the zone")
    }

    func testALineIsHitWithinItsTouchTarget() {
        let line = ImmersiveMapPolyline(id: 3, coordinates: [GeoCoordinate(latitude: 0, longitude: 0),
                                                             GeoCoordinate(latitude: 0, longitude: 10)])
        let entries = [Self.entry(ImmersiveMapLayer(source: "lines"), polylines: [line])]

        XCTAssertEqual(hit(entries, latitude: 0.05, longitude: 5)?.shapeID, 3, "Five pixels off a thin line")
        XCTAssertNil(hit(entries, latitude: 0.2, longitude: 5), "Twenty pixels off")
    }

    func testTheLayerDrawnLastIsAskedFirst() {
        let entries = [Self.entry(ImmersiveMapLayer(source: "under"), polygons: [Self.square(from: 0, to: 10)]),
                       Self.entry(ImmersiveMapLayer(source: "over"), polygons: [Self.square(from: 4, to: 6)])]

        XCTAssertEqual(hit(entries, latitude: 5, longitude: 5)?.layerID, "over")
        XCTAssertEqual(hit(entries, latitude: 2, longitude: 2)?.layerID, "under")
    }

    func testShapesGoByTheirOwnIdOrTheirPlaceInTheSource() {
        let content = LayerSourceContent(polygons: [Self.square(from: 0, to: 1), Self.square(id: 40, from: 0, to: 1)],
                                         polylines: [ImmersiveMapPolyline(coordinates: [])],
                                         points: [ImmersiveMapPoint(coordinate: GeoCoordinate(latitude: 0, longitude: 0))])
        XCTAssertEqual(content.polygons.map(\.id), [0, 40])
        XCTAssertEqual(content.polylines.map(\.id), [2])
        XCTAssertEqual(content.points.map(\.id), [3])
    }

    func testAGeoJSONFeaturesShapesGoByItsNumericIdOrItsPlace() throws {
        let json = """
        {"type": "FeatureCollection", "features": [
          {"type": "Feature", "id": 12, "geometry": {"type": "MultiPoint", "coordinates": [[1, 2], [3, 4]]}},
          {"type": "Feature", "id": "station-a", "geometry": {"type": "Point", "coordinates": [5, 6]}},
          {"type": "Feature", "geometry": {"type": "Point", "coordinates": [7, 8]}}
        ]}
        """
        let shapes = try ImmersiveMapGeoJSON.decode(Data(json.utf8))
        XCTAssertEqual(shapes.points.map(\.id), [12, 12, 1, 2],
                       "A feature's parts share its id, and a feature with no numeric id goes by its place")
    }

    func testALayersKindNamesItsLayer() {
        let kind = ImmersiveMapSelection.Kind.layer("zones")
        XCTAssertEqual(kind.layerID, "zones")
        XCTAssertNil(ImmersiveMapSelection.Kind.pin.layerID)
        XCTAssertNotEqual(kind, .layer("parks"))
    }
}

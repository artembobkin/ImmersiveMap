// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End to end: a layer's zone and point under the camera show in a headless
/// frame on the globe and on the flat map, and a zone on the far side of
/// the planet does not. Requires the compiled Metal library, so it skips
/// under `swift test` and runs in the xcodebuild workspace suite.
final class LayerOffscreenRenderTests: XCTestCase {
    private static let centre = GeoCoordinate(latitude: 10, longitude: 20)
    private static let red = SIMD4<Float>(1, 0, 0, 1)
    private static let green = SIMD4<Float>(0, 1, 0, 1)

    private static func square(around centre: GeoCoordinate, halfSide: Double) -> ImmersiveMapPolygon {
        ImmersiveMapPolygon(exterior: [
            GeoCoordinate(latitude: centre.latitude - halfSide, longitude: centre.longitude - halfSide),
            GeoCoordinate(latitude: centre.latitude - halfSide, longitude: centre.longitude + halfSide),
            GeoCoordinate(latitude: centre.latitude + halfSide, longitude: centre.longitude + halfSide),
            GeoCoordinate(latitude: centre.latitude + halfSide, longitude: centre.longitude - halfSide)
        ])
    }

    private static func isRed(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 200 && pixel.green < 60 && pixel.blue < 60
    }

    private static func isGreen(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.green > 200 && pixel.red < 60 && pixel.blue < 60
    }

    private static func settings(layers: [ImmersiveMapLayer]) -> ImmersiveMapSettings {
        var settings = ImmersiveMapSettings.default
        settings.scene.starfield.starCount = 0
        // Under the globe's sun a colour is shaded by the time of day: the
        // test reads the layer's own.
        settings.scene.globeLight.isEnabled = false
        settings.scene.atmosphere.isEnabled = false
        settings.scene.groundFog.isEnabled = false
        settings.scene.mountainGroundFog = nil
        return settings.layers(layers)
    }

    /// Renders until `isDone` holds for a frame (the layer is built off the
    /// main thread) or the frames run out, and returns the last frame.
    @MainActor
    private func render(_ harness: OffscreenFrameHarness, until isDone: (RenderedFrame) -> Bool) async throws -> RenderedFrame {
        var frame = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        for index in 1 ... 100 where isDone(frame) == false {
            try await Task.sleep(for: .milliseconds(20))
            frame = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(index))
        }
        return frame
    }

    @MainActor
    func testAZoneAndAPointShowOnTheGlobe() async throws {
        let zone = ImmersiveMapLayer(id: "zone",
                                     polygons: [Self.square(around: Self.centre, halfSide: 15)],
                                     polygonStyle: ImmersiveMapPolygonStyle(fillColor: Self.red, strokeWidthPoints: 0))
        // A point a little off the centre, so it does not hide the zone.
        let point = ImmersiveMapLayer(id: "point",
                                      points: [ImmersiveMapPoint(coordinate: GeoCoordinate(latitude: 30, longitude: 20))],
                                      pointStyle: ImmersiveMapPointStyle(color: Self.green, radiusPoints: 6, strokeWidthPoints: 0))
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: Self.settings(layers: [zone, point]))
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: Self.centre.latitude,
                                                             longitudeDegrees: Self.centre.longitude,
                                                             zoom: 1))
        let frame = try await render(harness) { Self.isRed($0.center) && $0.contains(where: Self.isGreen) }
        XCTAssertTrue(Self.isRed(frame.center), "The zone under the camera covers the centre: \(frame.center)")
        XCTAssertTrue(frame.contains(where: Self.isGreen), "The point shows north of the centre")
        XCTAssertFalse(frame.corners.contains(where: Self.isRed), "The zone stays on its part of the globe")
    }

    @MainActor
    func testAZoneOnTheFarSideOfTheGlobeDoesNotShow() async throws {
        let antipode = GeoCoordinate(latitude: -Self.centre.latitude, longitude: Self.centre.longitude - 180)
        let zone = ImmersiveMapLayer(id: "zone",
                                     polygons: [Self.square(around: antipode, halfSide: 30)],
                                     polylines: [ImmersiveMapPolyline(coordinates: [
                                         GeoCoordinate(latitude: antipode.latitude, longitude: antipode.longitude - 40),
                                         GeoCoordinate(latitude: antipode.latitude, longitude: antipode.longitude + 40)])],
                                     points: [ImmersiveMapPoint(coordinate: antipode)],
                                     polygonStyle: ImmersiveMapPolygonStyle(fillColor: Self.red, strokeColor: Self.red),
                                     polylineStyle: ImmersiveMapPolylineStyle(color: Self.red, widthPoints: 8),
                                     pointStyle: ImmersiveMapPointStyle(color: Self.red, radiusPoints: 20))
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: Self.settings(layers: [zone]))
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: Self.centre.latitude,
                                                             longitudeDegrees: Self.centre.longitude,
                                                             zoom: 1))
        // Give the build its time, then read the frame.
        var frame = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        for index in 1 ... 20 {
            try await Task.sleep(for: .milliseconds(20))
            frame = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(index))
        }
        XCTAssertEqual(frame.count(where: Self.isRed), 0, "Nothing of a layer on the far side shows through the planet")
    }

    @MainActor
    func testAZoneAndAPointShowOnTheFlatMap() async throws {
        let zone = ImmersiveMapLayer(id: "zone",
                                     polygons: [Self.square(around: Self.centre, halfSide: 0.002)],
                                     polygonStyle: ImmersiveMapPolygonStyle(fillColor: Self.red, strokeWidthPoints: 0))
        let point = ImmersiveMapLayer(id: "point",
                                      points: [ImmersiveMapPoint(coordinate: GeoCoordinate(latitude: Self.centre.latitude + 0.004,
                                                                                           longitude: Self.centre.longitude))],
                                      pointStyle: ImmersiveMapPointStyle(color: Self.green, radiusPoints: 6, strokeWidthPoints: 0))
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: Self.settings(layers: [zone, point]))
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: Self.centre.latitude,
                                                             longitudeDegrees: Self.centre.longitude,
                                                             zoom: 14))
        let frame = try await render(harness) { Self.isRed($0.center) && $0.contains(where: Self.isGreen) }
        XCTAssertTrue(Self.isRed(frame.center), "The zone under the camera covers the centre: \(frame.center)")
        XCTAssertTrue(frame.contains(where: Self.isGreen), "The point shows north of the centre")
        XCTAssertFalse(frame.corners.contains(where: Self.isRed), "The zone keeps to its few hundred metres")
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The flat map's coverage by ring rules: the ground in view cut into
/// bands by the distance in tiles from the look-at tile, one band per
/// rule, each drawn at the rule's zoom, nothing beyond the last rule and
/// nothing outside the footprint.
final class FlatRingRuleCoverageTests: XCTestCase {
    private struct Fixture {
        let flatRenderState: FlatRenderState
        let polygon: CoveragePolygon
    }

    /// The render camera as the engine poses it (`RenderCameraPoseResolver`,
    /// `RenderCamera`): the look-at at the world origin, the eye at the
    /// camera distance, pitched and turned, over the flat world of
    /// `PresentationStateResolver`.
    private static func makeFixture(zoom: Double,
                                    pitchDegrees: Double,
                                    bearingDegrees: Double = 0,
                                    aspect: Float = 4 / 3) throws -> Fixture {
        let settings = ImmersiveMapSettings.default.presentation
        let center = ImmersiveMapProjection.worldMercator(latitude: 40.7 * .pi / 180, longitude: -74 * .pi / 180)
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: center,
                                                  zoom: zoom,
                                                  bearing: Float(bearingDegrees * .pi / 180),
                                                  pitch: Float(pitchDegrees * .pi / 180))
        let presentation = PresentationStateResolver.resolve(cameraState: cameraState,
                                                             settings: settings,
                                                             forcedRenderSurfaceMode: .flat)
        let camera = RenderCamera()
        camera.recalculateProjection(aspect: aspect)
        RenderCameraPoseResolver().updateIfNeeded(camera: camera,
                                                  cameraState: cameraState,
                                                  transition: presentation.presentationState.transition)
        let cameraMatrix = try XCTUnwrap(camera.cameraMatrix)
        return Fixture(flatRenderState: presentation.flatRenderState,
                       polygon: try XCTUnwrap(CoveragePolygonBuilder.make(cameraMatrix: cameraMatrix)))
    }

    private static func resolve(_ fixture: Fixture,
                                targetZoom: Int,
                                rules: FlatRingRules = .default,
                                backdropZoom: Int? = TileCulling.flatBackdropZoomLevel) -> FlatRingRuleCoverageResolution {
        FlatRingRuleCoverage.resolve(flatRenderState: fixture.flatRenderState,
                                     targetZoom: targetZoom,
                                     backdropZoom: backdropZoom,
                                     rules: rules,
                                     polygon: fixture.polygon)
    }

    private static func rect(of tile: VisibleTile, fixture: Fixture) -> FlatRingSquare {
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x, y: tile.y, z: tile.z, worldWrap: tile.worldWrap,
                                                                  flatRenderPan: fixture.flatRenderState.pan,
                                                                  renderMapSize: fixture.flatRenderState.renderMapSize)
        return FlatRingSquare(minX: Double(origin.x), minY: Double(origin.y),
                              maxX: Double(origin.x) + Double(origin.z), maxY: Double(origin.y) + Double(origin.z))
    }

    /// Whether the two rectangles share ground, more than an edge.
    private static func overlap(_ a: FlatRingSquare, _ b: FlatRingSquare) -> Bool {
        let slack = 1e-4
        return a.minX < b.maxX - slack && a.maxX > b.minX + slack && a.minY < b.maxY - slack && a.maxY > b.minY + slack
    }

    private static func lies(_ a: FlatRingSquare, inside b: FlatRingSquare) -> Bool {
        let slack = 1e-4
        return a.minX >= b.minX - slack && a.maxX <= b.maxX + slack && a.minY >= b.minY - slack && a.maxY <= b.maxY + slack
    }

    private static func meetsFootprint(_ tile: VisibleTile, fixture: Fixture) -> Bool {
        let rect = rect(of: tile, fixture: fixture)
        return fixture.polygon.intersects(minX: rect.minX, minY: rect.minY, maxX: rect.maxX, maxY: rect.maxY)
    }

    // MARK: - The rules

    func testTheRulesAreNormalized() {
        let messy = FlatRingRules(rules: [FlatRingRule(zoomDrop: 3, distance: 4),
                                          FlatRingRule(zoomDrop: -1, distance: 1),
                                          FlatRingRule(zoomDrop: 99, distance: -5),
                                          FlatRingRule(zoomDrop: 1, distance: 4),
                                          FlatRingRule(zoomDrop: 2, distance: 100_000)])
        let normalized = messy.normalized()
        XCTAssertEqual(normalized.rules.map(\.distance), [0, 1, 4, FlatRingRules.distanceRange.upperBound])
        XCTAssertEqual(normalized.rules.map(\.zoomDrop), [FlatRingRules.zoomDropRange.upperBound, 0, 3, 2],
                       "drops clamped, the first of two rules at one distance kept")
        XCTAssertEqual(FlatRingRules(rules: []).normalized(), FlatRingRules.default, "at least one rule")
        XCTAssertEqual(FlatRingRules.default.normalized(), FlatRingRules.default, "the default is already normal")
        XCTAssertEqual(FlatRingRules.default.rules.map(\.zoomDrop), [0, 1, 2, 4])
        XCTAssertEqual(FlatRingRules.default.rules.map(\.distance), [1, 2, 3, 9])
        XCTAssertEqual(FlatRingRules.default.rules.map(\.drawsLines), [true, true, false, false])
    }

    // MARK: - The look-at tile and its squares

    /// The look-at tile is the target tile that holds the world origin,
    /// and a rule's square is that tile and its rings, whole tiles a side.
    func testTheSquareIsTheLookAtTileAndItsRings() throws {
        for zoom in [3, 9, 16] {
            let fixture = try Self.makeFixture(zoom: Double(zoom), pitchDegrees: 60, bearingDegrees: 33)
            let tile = FlatRingRuleCoverage.lookAtTile(targetZoom: zoom, flatRenderState: fixture.flatRenderState)
            let rect = Self.rect(of: VisibleTile(x: tile.x, y: tile.y, z: zoom, worldWrap: 0), fixture: fixture)
            XCTAssertTrue(rect.minX <= 1e-4 && rect.maxX >= -1e-4 && rect.minY <= 1e-4 && rect.maxY >= -1e-4,
                          "z\(zoom): the look-at tile \(tile) holds the origin, \(rect)")
            let size = rect.maxX - rect.minX
            let alone = FlatRingRuleCoverage.square(rings: 0, targetZoom: zoom, flatRenderState: fixture.flatRenderState)
            XCTAssertEqual(alone.minX, rect.minX, accuracy: 1e-4)
            XCTAssertEqual(alone.maxY, rect.maxY, accuracy: 1e-4)
            let three = FlatRingRuleCoverage.square(rings: 3, targetZoom: zoom, flatRenderState: fixture.flatRenderState)
            XCTAssertEqual(three.maxX - three.minX, size * 7, accuracy: 1e-3)
            XCTAssertEqual(three.maxY - three.minY, size * 7, accuracy: 1e-3)
            XCTAssertEqual(three.minX, rect.minX - size * 3, accuracy: 1e-3)
        }
    }

    // MARK: - The coverage

    /// One rule, whatever the pose: the band is exactly the target tiles
    /// the footprint meets inside the rule's square. Nothing outside the
    /// footprint, nothing beyond the rings, nothing in view inside the
    /// rings missing.
    func testABandIsTheFootprintInsideItsSquare() throws {
        let rules = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 2)])
        for pitchDegrees in [0.0, 40.0, 64.0, 75.0] {
            for bearingDegrees in stride(from: 0.0, to: 360.0, by: 17.0) {
                let fixture = try Self.makeFixture(zoom: 15.07, pitchDegrees: pitchDegrees, bearingDegrees: bearingDegrees)
                let resolution = Self.resolve(fixture, targetZoom: 15, rules: rules)
                let square = FlatRingRuleCoverage.square(rings: 2, targetZoom: 15, flatRenderState: fixture.flatRenderState)
                let inView = FlatTileCoverage.tiles(atZoom: 15, polygon: fixture.polygon, flatRenderState: fixture.flatRenderState)
                let expected = inView.filter { Self.lies(Self.rect(of: $0, fixture: fixture), inside: square) }
                XCTAssertEqual(Set(resolution.targets), Set(expected), "pitch \(pitchDegrees) bearing \(bearingDegrees)")
                XCTAssertFalse(expected.isEmpty)
                XCTAssertLessThanOrEqual(resolution.targets.count, 25)
            }
        }
    }

    /// A turn of the camera never changes a tile's rule: a tile two
    /// bearings both place is at the same zoom in both, and a tile only
    /// one of them places is outside the other's footprint.
    func testATurnOnlyChangesWhatTheFootprintHolds() throws {
        let rules = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 1),
                                          FlatRingRule(zoomDrop: 1, distance: 5),
                                          FlatRingRule(zoomDrop: 3, distance: 23)])
        let bearings = Array(stride(from: 0.0, to: 360.0, by: 9.0))
        let fixtures = try bearings.map { try Self.makeFixture(zoom: 15.07, pitchDegrees: 70, bearingDegrees: $0) }
        let placed = fixtures.map { Set(Self.resolve($0, targetZoom: 15, rules: rules).targets) }
        let everPlaced = placed.reduce(into: Set<VisibleTile>()) { $0.formUnion($1) }
        XCTAssertGreaterThan(everPlaced.count, placed[0].count, "the turn brings tiles in and out")
        for (index, fixture) in fixtures.enumerated() {
            for tile in everPlaced where placed[index].contains(tile) == false {
                // Drawn in by the band's inset the tile may still touch the
                // footprint along an edge: what it must not do is reach
                // into it.
                let rect = Self.rect(of: tile, fixture: fixture)
                let inset = (rect.maxX - rect.minX) * 0.01
                XCTAssertFalse(fixture.polygon.intersects(minX: rect.minX + inset, minY: rect.minY + inset,
                                                          maxX: rect.maxX - inset, maxY: rect.maxY - inset)
                                && Self.bandHolds(tile, rules: rules, fixture: fixture),
                               "bearing \(bearings[index]): \(tile) is in view in its band and not placed")
            }
        }
    }

    /// Whether the tile has ground in the band of its own zoom's rule:
    /// inside the rule's square and outside the previous rule's.
    private static func bandHolds(_ tile: VisibleTile, rules: FlatRingRules, fixture: Fixture) -> Bool {
        let rect = rect(of: tile, fixture: fixture)
        var inner: FlatRingSquare?
        for rule in rules.normalized().rules {
            let square = FlatRingRuleCoverage.square(rings: rule.distance, targetZoom: 15, flatRenderState: fixture.flatRenderState)
            defer { inner = square }
            guard 15 - rule.zoomDrop == tile.z else { continue }
            let pieces = FlatRingRuleCoverage.bandPolygons(fixture.polygon, square: square, innerSquare: inner,
                                                           inset: (rect.maxX - rect.minX) * 0.01)
            return pieces.contains { $0.intersects(minX: rect.minX, minY: rect.minY, maxX: rect.maxX, maxY: rect.maxY) }
        }
        return false
    }

    /// At a street tilt every rule has ground: each tile is at a rule's
    /// zoom, reaches into that rule's square, is not wholly under the
    /// previous rule's, and meets the footprint. In the renderer's order
    /// and the same twice.
    func testAStreetTiltPlacesEachRulesBand() throws {
        let rules = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 0),
                                          FlatRingRule(zoomDrop: 1, distance: 2),
                                          FlatRingRule(zoomDrop: 4, distance: 40)])
        let fixture = try Self.makeFixture(zoom: 16, pitchDegrees: 75, bearingDegrees: 47)
        let resolution = Self.resolve(fixture, targetZoom: 16, rules: rules)
        XCTAssertEqual(resolution.bands.map(\.zoom), [16, 15, 12])
        XCTAssertEqual(resolution.bands.map(\.distance), [0, 2, 40])
        XCTAssertEqual(resolution.bands[0].tileCount, 1, "the look-at tile alone")
        XCTAssertTrue(resolution.bands.allSatisfy { $0.tileCount > 0 }, "every rule has ground at a street tilt: \(resolution.bands)")
        let squares = rules.rules.map { FlatRingRuleCoverage.square(rings: $0.distance, targetZoom: 16, flatRenderState: fixture.flatRenderState) }
        for target in resolution.targets {
            let index = try XCTUnwrap(rules.rules.firstIndex { 16 - $0.zoomDrop == target.z }, "\(target) is at a rule's zoom")
            let rect = Self.rect(of: target, fixture: fixture)
            XCTAssertTrue(Self.overlap(rect, squares[index]), "\(target) reaches into its rule's square")
            if index > 0 {
                XCTAssertFalse(Self.lies(rect, inside: squares[index - 1]), "\(target) is not wholly under the nearer band")
            }
            XCTAssertTrue(Self.meetsFootprint(target, fixture: fixture), "\(target) is in view")
        }
        XCTAssertEqual(resolution.targets, FlatTileCoverage.sorted(resolution.targets), "finest first, stable")
        XCTAssertEqual(Set(resolution.targets).count, resolution.targets.count)
        XCTAssertLessThanOrEqual(resolution.targets.count, 40, "a few tiles per band: \(resolution.bands)")
        let again = Self.resolve(fixture, targetZoom: 16, rules: rules)
        XCTAssertEqual(again.targets, resolution.targets, "deterministic")
        XCTAssertEqual(again.bands, resolution.bands)
    }

    /// The bands leave no hole: every point of the footprint inside the
    /// last rule's square lies in a placed tile.
    func testTheBandsCoverTheFootprintInsideTheLastSquare() throws {
        let rules = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 1),
                                          FlatRingRule(zoomDrop: 2, distance: 6),
                                          FlatRingRule(zoomDrop: 4, distance: 30)])
        for bearingDegrees in [0.0, 36.0, 89.0, 200.0] {
            let fixture = try Self.makeFixture(zoom: 15.07, pitchDegrees: 70, bearingDegrees: bearingDegrees)
            let resolution = Self.resolve(fixture, targetZoom: 15, rules: rules)
            let rects = resolution.targets.map { Self.rect(of: $0, fixture: fixture) }
            let last = FlatRingRuleCoverage.square(rings: 30, targetZoom: 15, flatRenderState: fixture.flatRenderState)
            let ground = try XCTUnwrap(FlatRingRuleCoverage.clipped(fixture.polygon, to: last))
            let vertices = ground.vertices.map { SIMD2<Double>($0) }
            let centroid = vertices.reduce(SIMD2<Double>(0, 0), +) / Double(vertices.count)
            var samples = 0
            for index in vertices.indices {
                let a = vertices[index], b = vertices[(index + 1) % vertices.count]
                for u in stride(from: 0.05, through: 0.95, by: 0.15) {
                    for v in stride(from: 0.05, through: 0.95, by: 0.15) {
                        let point = centroid + (a + (b - a) * u - centroid) * v
                        samples += 1
                        XCTAssertTrue(rects.contains { point.x >= $0.minX - 1e-3 && point.x <= $0.maxX + 1e-3
                                          && point.y >= $0.minY - 1e-3 && point.y <= $0.maxY + 1e-3 },
                                      "bearing \(bearingDegrees): \(point) is in view inside the last square and under no tile")
                    }
                }
            }
            XCTAssertGreaterThan(samples, 100)
        }
    }

    /// A shorter last rule leaves more of the far ground to the haze and
    /// places fewer tiles. A longer one reaches farther.
    func testTheLastRuleIsTheReach() throws {
        let fixture = try Self.makeFixture(zoom: 16, pitchDegrees: 75)
        let short = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 1), FlatRingRule(zoomDrop: 2, distance: 3)])
        let long = FlatRingRules(rules: short.rules + [FlatRingRule(zoomDrop: 5, distance: 60)])
        let shortResolution = Self.resolve(fixture, targetZoom: 16, rules: short)
        let longResolution = Self.resolve(fixture, targetZoom: 16, rules: long)
        XCTAssertLessThan(shortResolution.targets.count, longResolution.targets.count)
        XCTAssertEqual(Set(shortResolution.targets), Set(longResolution.targets.filter { $0.z >= 14 }),
                       "the shared rules place the same tiles")
        let reach = FlatRingRuleCoverage.square(rings: 3, targetZoom: 16, flatRenderState: fixture.flatRenderState)
        for target in shortResolution.targets {
            XCTAssertTrue(Self.overlap(Self.rect(of: target, fixture: fixture), reach), "\(target) is not beyond the last rule")
        }
    }

    /// A rule's drop never reaches below the world cover's zoom, and
    /// without one the floor is the world tile.
    func testTheDropIsFlooredByTheBackdrop() throws {
        let fixture = try Self.makeFixture(zoom: 3, pitchDegrees: 75)
        let deep = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 0), FlatRingRule(zoomDrop: 8, distance: 7)])
        let withBackdrop = Self.resolve(fixture, targetZoom: 3, rules: deep)
        XCTAssertEqual(withBackdrop.bands.map(\.zoom), [3, TileCulling.flatBackdropZoomLevel + 1])
        XCTAssertTrue(withBackdrop.targets.allSatisfy { $0.z > TileCulling.flatBackdropZoomLevel })
        let without = Self.resolve(fixture, targetZoom: 3, rules: deep, backdropZoom: nil)
        XCTAssertEqual(without.bands.map(\.zoom), [3, 0])
        XCTAssertTrue(without.targets.contains { $0.z == 0 })
    }

    // MARK: - The readout

    func testTheRulesReadoutLine() {
        let bands = [FlatRingBand(zoom: 16, distance: 0, tileCount: 1),
                     FlatRingBand(zoom: 14, distance: 3, tileCount: 3),
                     FlatRingBand(zoom: 11, distance: 40, tileCount: 2)]
        XCTAssertEqual(DebugOverlayHUDSnapshot.ringRulesLine(bands),
                       "rules: z16 \u{2264}0 (1) / z14 \u{2264}3 (3) / z11 \u{2264}40 (2)")
        XCTAssertEqual(DebugOverlayHUDSnapshot.ringRulesLine([]), "rules: none")
    }

    func testTheRulesAreTheDebugPanels() {
        let controls = DebugOverlayControlState()
        XCTAssertEqual(controls.snapshot().ringRuleSets, .default)
        let edited = FlatRingRules(rules: [FlatRingRule(zoomDrop: 1, distance: 3), FlatRingRule(zoomDrop: 0, distance: 1)])
        controls.setRingRuleSets(RingRuleSets(sets: [RingRuleSet(firstZoom: 0, rules: edited)]))
        XCTAssertEqual(controls.snapshot().ringRuleSets.rules(forTargetZoom: 12), edited.normalized())
        XCTAssertEqual(controls.snapshot().ringRuleSets.sets[0].rules.rules.map(\.distance), [1, 3], "stored sorted")
    }

    #if os(macOS)
    /// The panel's distance slider runs on the square root of the ring
    /// number: every ring number comes back from its own slider value. The
    /// slider helpers belong to an `NSView`, so they are main actor isolated
    /// (Xcode 16.4 rejects the call from a nonisolated test).
    @MainActor
    func testThePanelsDistanceSliderReadsEveryRing() {
        for distance in FlatRingRules.distanceRange {
            let value = DebugOverlayHUDView.ringRuleSliderValue(distance: distance)
            XCTAssertTrue(DebugOverlayHUDView.ringRuleSliderRange.contains(value))
            XCTAssertEqual(DebugOverlayHUDView.ringRuleDistance(sliderValue: value), distance)
        }
        XCTAssertEqual(DebugOverlayHUDView.ringRuleDistance(sliderValue: 1_000), FlatRingRules.distanceRange.upperBound)
    }
    #endif
}

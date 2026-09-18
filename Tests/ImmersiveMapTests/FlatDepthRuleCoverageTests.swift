// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The flat map's coverage by depth rules: the ground in view cut into
/// bands by depth along the view axis, one band per rule, each drawn at
/// the rule's zoom, nothing beyond the last rule.
final class FlatDepthRuleCoverageTests: XCTestCase {
    private struct Fixture {
        let eye: SIMD3<Float>
        let flatRenderState: FlatRenderState
        let polygon: CoveragePolygon
        let cameraDistance: Double
    }

    /// The render camera as the engine poses it (`RenderCameraPoseResolver`,
    /// `RenderCamera`): the look-at at the world origin, the eye at the
    /// camera distance, pitched, over the flat world of
    /// `PresentationStateResolver`.
    private static func makeFixture(zoom: Double, pitchDegrees: Double, aspect: Float = 4 / 3) throws -> Fixture {
        let settings = ImmersiveMapSettings.default.presentation
        let center = ImmersiveMapProjection.worldMercator(latitude: 40.7 * .pi / 180, longitude: -74 * .pi / 180)
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: center,
                                                  zoom: zoom,
                                                  bearing: 0,
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
        let eye = camera.eye
        return Fixture(eye: eye,
                       flatRenderState: presentation.flatRenderState,
                       polygon: try XCTUnwrap(CoveragePolygonBuilder.make(cameraMatrix: cameraMatrix)),
                       cameraDistance: Double(simd_length(eye)))
    }

    private static func resolve(_ fixture: Fixture,
                                targetZoom: Int,
                                rules: FlatDepthRules = .default,
                                backdropZoom: Int? = TileCulling.flatBackdropZoomLevel) -> FlatDepthRuleCoverageResolution {
        FlatDepthRuleCoverage.resolve(eye: fixture.eye,
                                      flatRenderState: fixture.flatRenderState,
                                      targetZoom: targetZoom,
                                      backdropZoom: backdropZoom,
                                      rules: rules,
                                      polygon: fixture.polygon)
    }

    /// The view depth of a tile's nearest corner, in camera distances.
    private static func nearestDepth(of tile: VisibleTile, fixture: Fixture) -> Double {
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x, y: tile.y, z: tile.z, worldWrap: tile.worldWrap,
                                                                  flatRenderPan: fixture.flatRenderState.pan,
                                                                  renderMapSize: fixture.flatRenderState.renderMapSize)
        let eye = SIMD3<Double>(Double(fixture.eye.x), Double(fixture.eye.y), Double(fixture.eye.z))
        let direction = -eye / simd_length(eye)
        var nearest = Double.infinity
        for corner in [SIMD2<Double>(Double(origin.x), Double(origin.y)),
                       SIMD2<Double>(Double(origin.x) + Double(origin.z), Double(origin.y)),
                       SIMD2<Double>(Double(origin.x), Double(origin.y) + Double(origin.z)),
                       SIMD2<Double>(Double(origin.x) + Double(origin.z), Double(origin.y) + Double(origin.z))] {
            nearest = min(nearest, simd_dot(SIMD3<Double>(corner.x, corner.y, 0) - eye, direction))
        }
        return nearest / fixture.cameraDistance
    }

    // MARK: - The rules

    func testTheRulesAreNormalized() {
        let messy = FlatDepthRules(rules: [FlatDepthRule(zoomDrop: 3, depth: 4),
                                           FlatDepthRule(zoomDrop: -1, depth: 1),
                                           FlatDepthRule(zoomDrop: 99, depth: .nan),
                                           FlatDepthRule(zoomDrop: 1, depth: 4),
                                           FlatDepthRule(zoomDrop: 2, depth: 1000)])
        let normalized = messy.normalized()
        XCTAssertEqual(normalized.rules.map(\.depth), [FlatDepthRules.depthRange.lowerBound, 1, 4, FlatDepthRules.depthRange.upperBound])
        XCTAssertEqual(normalized.rules.map(\.zoomDrop), [FlatDepthRules.zoomDropRange.upperBound, 0, 3, 2],
                       "drops clamped, the first of two rules at one depth kept")
        XCTAssertEqual(FlatDepthRules(rules: []).normalized(), FlatDepthRules.default, "at least one rule")
        XCTAssertEqual(FlatDepthRules.default.normalized(), FlatDepthRules.default, "the default is already normal")
        XCTAssertEqual(FlatDepthRules.default.rules.map(\.zoomDrop), [0, 1, 2, 5])
        XCTAssertEqual(FlatDepthRules.default.rules.map(\.rasterized), [false, true, true, true])
        XCTAssertEqual(FlatDepthRules.default.rules.map(\.rasterResolution), [1024, 512, 256, 256])
    }

    // MARK: - The depth lines

    /// A depth line on the ground is where the view depth equals the
    /// given value: every point on it reads that depth back.
    func testTheDepthLineIsWhereTheViewDepthIsReached() throws {
        let fixture = try Self.makeFixture(zoom: 16, pitchDegrees: 60)
        let eye = SIMD3<Double>(Double(fixture.eye.x), Double(fixture.eye.y), Double(fixture.eye.z))
        let direction = -eye / simd_length(eye)
        for depth in [0.5, 1.0, 2.5] {
            let (a, b) = try XCTUnwrap(FlatDepthRuleCoverage.depthLine(eye: eye, direction: direction, depth: depth * fixture.cameraDistance))
            for point in [a, b, (a + b) / 2] {
                let measured = simd_dot(SIMD3<Double>(point.x, point.y, 0) - eye, direction) / fixture.cameraDistance
                XCTAssertEqual(measured, depth, accuracy: 1e-9)
            }
            XCTAssertNotEqual(a, b)
        }
        // Straight down there is no line: the ground is one depth.
        let topDown = try Self.makeFixture(zoom: 16, pitchDegrees: 0)
        let downEye = SIMD3<Double>(Double(topDown.eye.x), Double(topDown.eye.y), Double(topDown.eye.z))
        XCTAssertNil(FlatDepthRuleCoverage.depthLine(eye: downEye, direction: -downEye / simd_length(downEye), depth: 1))
    }

    // MARK: - The coverage

    /// Straight down the whole ground lies at depth 1: it belongs to the
    /// first rule that covers it, at the target zoom, the footprint's
    /// tiles each once.
    func testTopDownIsTheFirstRuleAtTheTargetZoom() throws {
        let fixture = try Self.makeFixture(zoom: 16, pitchDegrees: 0)
        let resolution = Self.resolve(fixture, targetZoom: 16)
        let plain = FlatTileCoverage.tiles(atZoom: 16, polygon: fixture.polygon, flatRenderState: fixture.flatRenderState)
        XCTAssertEqual(resolution.targets, FlatTileCoverage.sorted(plain))
        XCTAssertEqual(resolution.bands.map(\.zoom), [16, 15, 14, 11])
        XCTAssertEqual(resolution.bands.map(\.tileCount), [plain.count, 0, 0, 0], "only the rule spanning depth 1 places tiles")
        XCTAssertGreaterThan(resolution.visitedNodeCount, plain.count)

        // Rules that all end nearer than the camera place nothing: the
        // backdrop paints.
        let near = FlatDepthRules(rules: [FlatDepthRule(zoomDrop: 0, depth: 0.5)])
        XCTAssertTrue(Self.resolve(fixture, targetZoom: 16, rules: near).targets.isEmpty)
    }

    /// At a street tilt every rule has ground: the near band at the target
    /// zoom, the farther ones at their drops, each tile in a band whose
    /// nearest corner is not beyond the band's depth, none beyond the last
    /// rule, in the renderer's order, the same twice, and about ten.
    func testAStreetTiltPlacesEachRulesBand() throws {
        let fixture = try Self.makeFixture(zoom: 16, pitchDegrees: 75)
        let resolution = Self.resolve(fixture, targetZoom: 16)
        XCTAssertEqual(resolution.bands.map(\.zoom), [16, 15, 14, 11])
        XCTAssertEqual(resolution.bands.map(\.depth), [1.3, 2.6, 5.86, 8.07])
        XCTAssertTrue(resolution.bands.allSatisfy { $0.tileCount > 0 }, "every rule has ground at a street tilt: \(resolution.bands)")
        let lastDepth = FlatDepthRules.default.rules.last!.depth
        for target in resolution.targets {
            let drop = 16 - target.z
            let rule = try XCTUnwrap(FlatDepthRules.default.rules.first { $0.zoomDrop == drop }, "\(target) is at a rule's zoom")
            let nearest = Self.nearestDepth(of: target, fixture: fixture)
            XCTAssertLessThanOrEqual(nearest, rule.depth + 1e-6, "\(target) reaches into its rule's band")
            XCTAssertLessThanOrEqual(nearest, lastDepth, "nothing beyond the last rule")
        }
        XCTAssertEqual(resolution.targets, FlatTileCoverage.sorted(resolution.targets), "finest first, stable")
        XCTAssertEqual(Set(resolution.targets).count, resolution.targets.count)
        XCTAssertLessThanOrEqual(resolution.targets.count, 24, "a few tiles per band: \(resolution.bands)")
        XCTAssertGreaterThanOrEqual(resolution.targets.count, 4)
        let again = Self.resolve(fixture, targetZoom: 16)
        XCTAssertEqual(again.targets, resolution.targets, "deterministic")
        XCTAssertEqual(again.bands, resolution.bands)
    }

    /// The count stays bounded through the tilts with no cap anywhere:
    /// the rules bound the reach and each band holds a few tiles.
    func testTheCountStaysNearTenThroughTheTilts() throws {
        for pitchDegrees in [0.0, 20.0, 40.0, 55.0, 65.0, 70.0, 75.0] {
            let fixture = try Self.makeFixture(zoom: 16, pitchDegrees: pitchDegrees)
            let resolution = Self.resolve(fixture, targetZoom: 16)
            XCTAssertLessThanOrEqual(resolution.targets.count, 24, "pitch \(pitchDegrees): \(resolution.bands)")
            XCTAssertGreaterThanOrEqual(resolution.targets.count, 2, "pitch \(pitchDegrees)")
        }
    }

    /// A shorter last rule leaves more of the far ground to the backdrop
    /// and places fewer tiles; a longer one reaches farther.
    func testTheLastRuleIsTheReach() throws {
        let fixture = try Self.makeFixture(zoom: 16, pitchDegrees: 75)
        let short = FlatDepthRules(rules: [FlatDepthRule(zoomDrop: 0, depth: 1.3), FlatDepthRule(zoomDrop: 2, depth: 2.6)])
        let long = FlatDepthRules(rules: short.rules + [FlatDepthRule(zoomDrop: 5, depth: 20)])
        let shortResolution = Self.resolve(fixture, targetZoom: 16, rules: short)
        let longResolution = Self.resolve(fixture, targetZoom: 16, rules: long)
        XCTAssertLessThan(shortResolution.targets.count, longResolution.targets.count)
        XCTAssertEqual(Set(shortResolution.targets), Set(longResolution.targets.filter { $0.z >= 14 }),
                       "the shared rules place the same tiles")
        for target in shortResolution.targets {
            XCTAssertLessThanOrEqual(Self.nearestDepth(of: target, fixture: fixture), 2.6 + 1e-6)
        }
    }

    /// A rule's drop never reaches below the backdrop's zoom, and without
    /// a backdrop the floor is the world tile.
    func testTheDropIsFlooredByTheBackdrop() throws {
        let fixture = try Self.makeFixture(zoom: 3, pitchDegrees: 75)
        let deep = FlatDepthRules(rules: [FlatDepthRule(zoomDrop: 0, depth: 1.3), FlatDepthRule(zoomDrop: 8, depth: 7)])
        let withBackdrop = Self.resolve(fixture, targetZoom: 3, rules: deep)
        XCTAssertEqual(withBackdrop.bands.map(\.zoom), [3, TileCulling.flatBackdropZoomLevel + 1])
        XCTAssertTrue(withBackdrop.targets.allSatisfy { $0.z > TileCulling.flatBackdropZoomLevel })
        let without = Self.resolve(fixture, targetZoom: 3, rules: deep, backdropZoom: nil)
        XCTAssertEqual(without.bands.map(\.zoom), [3, 0])
        XCTAssertTrue(without.targets.contains { $0.z == 0 })
    }

    /// A camera at the origin has no view axis: nothing is placed rather
    /// than a division by zero.
    func testADegenerateEyePlacesNothing() throws {
        let fixture = try Self.makeFixture(zoom: 16, pitchDegrees: 75)
        let resolution = FlatDepthRuleCoverage.resolve(eye: SIMD3<Float>(0, 0, 0),
                                                       flatRenderState: fixture.flatRenderState,
                                                       targetZoom: 16,
                                                       backdropZoom: 0,
                                                       rules: .default,
                                                       polygon: fixture.polygon)
        XCTAssertTrue(resolution.targets.isEmpty)
        XCTAssertTrue(resolution.bands.isEmpty)
    }

    // MARK: - The readout

    func testTheRulesReadoutLine() {
        let bands = [FlatDepthBand(zoom: 16, depth: 1.3, tileCount: 4),
                     FlatDepthBand(zoom: 14, depth: 2.6, tileCount: 3),
                     FlatDepthBand(zoom: 11, depth: 7, tileCount: 2, rasterResolution: 512)]
        XCTAssertEqual(DebugOverlayHUDSnapshot.depthRulesLine(bands),
                       "rules: z16 \u{2264}1.3 (4) / z14 \u{2264}2.6 (3) / z11 \u{2264}7.0 (2) raster 512")
        XCTAssertEqual(DebugOverlayHUDSnapshot.depthRulesLine([]), "rules: none")
    }

    // MARK: - Rasterized rules

    func testARasterResolutionIsOneOfTheOptions() {
        let rules = FlatDepthRules(rules: [FlatDepthRule(zoomDrop: 0, depth: 1, rasterized: true, rasterResolution: 700),
                                           FlatDepthRule(zoomDrop: 2, depth: 2, rasterized: false, rasterResolution: 9000)])
        let normalized = rules.normalized().rules
        XCTAssertEqual(normalized.map(\.rasterResolution), [512, 2048], "the nearest option")
        XCTAssertEqual(normalized.map(\.rasterized), [true, false])
        XCTAssertEqual(FlatDepthRules.clampedRasterResolution(0), 256)
        XCTAssertEqual(FlatDepthRule(zoomDrop: 0, depth: 1).rasterized, false, "vector unless asked")
    }

    /// A rasterized rule's tiles are the raster targets at its resolution.
    /// A tile the nearer vector band already placed stays vector, so the
    /// nearer band's answer wins where two bands share a tile.
    func testARasterizedRulesTilesAreTheRasterTargets() throws {
        let fixture = try Self.makeFixture(zoom: 16, pitchDegrees: 75)
        let rules = FlatDepthRules(rules: [FlatDepthRule(zoomDrop: 0, depth: 1.3),
                                           FlatDepthRule(zoomDrop: 2, depth: 2.6, rasterized: true, rasterResolution: 1024),
                                           FlatDepthRule(zoomDrop: 5, depth: 7)])
        let resolution = Self.resolve(fixture, targetZoom: 16, rules: rules)
        let rasterized = resolution.rasterizedTargets
        XCTAssertFalse(rasterized.isEmpty, "The second band has tiles")
        XCTAssertTrue(rasterized.values.allSatisfy { $0 == 1024 })
        XCTAssertTrue(rasterized.keys.allSatisfy { $0.z == 14 }, "Only the rasterized band's tiles")
        XCTAssertTrue(rasterized.keys.allSatisfy { resolution.targets.contains($0) })
        XCTAssertEqual(resolution.bands.map(\.rasterResolution), [nil, 1024, nil])

        let vectorOnly = Self.resolve(fixture, targetZoom: 16, rules: FlatDepthRules(rules: rules.rules.map {
            FlatDepthRule(zoomDrop: $0.zoomDrop, depth: $0.depth)
        }))
        XCTAssertTrue(vectorOnly.rasterizedTargets.isEmpty)
        XCTAssertEqual(vectorOnly.targets, resolution.targets, "Rasterizing changes how a band draws, not what it places")
    }

    func testTheRulesAreTheDebugPanels() {
        let controls = DebugOverlayControlState()
        XCTAssertEqual(controls.snapshot().flatDepthRules, .default)
        let edited = FlatDepthRules(rules: [FlatDepthRule(zoomDrop: 1, depth: 3), FlatDepthRule(zoomDrop: 0, depth: 1)])
        controls.setFlatDepthRules(edited)
        XCTAssertEqual(controls.snapshot().flatDepthRules, edited.normalized())
        XCTAssertEqual(controls.snapshot().flatDepthRules.rules.map(\.depth), [1, 3], "stored sorted")
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The building footprints on screen: the radius baked per building and
/// per ground fill, and the fade of the flat building fills by it. The
/// extruded buildings draw whole at every size.
final class BuildingFootprintTests: XCTestCase {
    func testTheFootprintRadiusHoldsEveryVertexOfTheBuilding() {
        let vertices = [SIMD3<Float>(100, 100, 0), SIMD3<Float>(140, 100, 0),
                        SIMD3<Float>(140, 130, 20), SIMD3<Float>(100, 130, 20)]
            .map { ParsedExtrudedVertex(position: $0, normal: SIMD3<Float>(0, 0, 1), surfaceID: 0) }
        let mesh = ParsedExtrudedMesh(vertices: vertices, indices: [0, 1, 2, 0, 2, 3])
        let radius = TileUnificationStage.footprintRadius(of: mesh)
        XCTAssertEqual(radius, 25, accuracy: 1e-4, "half the diagonal of a 40 by 30 footprint")
        XCTAssertEqual(TileUnificationStage.footprintRadius(of: ParsedExtrudedMesh(vertices: [], indices: [])), 0)
    }

    func testTheVertexCarriesTheRadiusInQuarterUnits() {
        let vertex = ExtrudedVertexIn(position: SIMD3<Float>(1, 2, 3), normal: SIMD3<Float>(0, 0, 1),
                                      styleIndex: 0, footprintRadius: 25.3)
        XCTAssertEqual(vertex.footprintRadius, 101)
        XCTAssertEqual(vertex.footprintRadiusUnits, 25.25)
        XCTAssertEqual(MemoryLayout<ExtrudedVertexIn>.stride, 12, "the radius takes the padding bytes")
        XCTAssertEqual(MemoryLayout<ExtrudedVertexIn>.offset(of: \.footprintRadius), 10)
        XCTAssertEqual(ExtrudedVertexIn(position: .zero, normal: .zero, styleIndex: 0).footprintRadius, 0)
    }

    /// A building fill's alpha follows its footprint on screen: gone at the
    /// gone area, whole at the opaque area, rising between them.
    func testTheAlphaFollowsTheFootprintArea() {
        XCTAssertEqual(BuildingFootprintFade(goneAreaPixels: 0, opaqueAreaPixels: 0).alpha(areaPixels: 0), 1,
                       "off, everything is whole")
        let fade = BuildingFootprintFade(goneAreaPixels: 100, opaqueAreaPixels: 2500)
        XCTAssertEqual(fade.alpha(areaPixels: 50), 0)
        XCTAssertEqual(fade.alpha(areaPixels: 100), 0)
        XCTAssertEqual(fade.alpha(areaPixels: 1300), 0.5, accuracy: 1e-4)
        XCTAssertEqual(fade.alpha(areaPixels: 2500), 1)
        XCTAssertEqual(fade.alpha(areaPixels: 9000), 1)
        XCTAssertLessThan(fade.alpha(areaPixels: 600), fade.alpha(areaPixels: 1200))
        XCTAssertEqual(BuildingFootprintFade.footprintAreaPixels(radiusPixels: 10), 200,
                       "the square inscribed in the disc of the radius")
    }

    /// A ground building fill carries its polygon's radius in the normal
    /// bytes, as two base-128 digits of quarter tile units.
    func testAGroundFillCarriesItsFootprintRadius() {
        XCTAssertEqual(TileVertexIn.footprintRadiusNormal(radiusUnits: 0), SIMD2<Int8>(0, 0))
        XCTAssertEqual(TileVertexIn.footprintRadiusNormal(radiusUnits: 25.25), SIMD2<Int8>(0, 101))
        XCTAssertEqual(TileVertexIn.footprintRadiusNormal(radiusUnits: 100), SIMD2<Int8>(3, 16), "400 quarter units")
        XCTAssertEqual(TileVertexIn.footprintRadiusNormal(radiusUnits: 1e6), SIMD2<Int8>(127, 127), "saturates at a tile")
        var polygon = ParsedPolygon()
        polygon.vertices = [SIMD2<Int16>(100, 100), SIMD2<Int16>(140, 100), SIMD2<Int16>(140, 130), SIMD2<Int16>(100, 130)]
        XCTAssertEqual(TileUnificationStage.footprintRadius(of: polygon), 25, accuracy: 1e-4)
        XCTAssertTrue(LowZoomOverviewFade.isFootprintFadeBand(mask: LowZoomOverviewFade.footprintFadeMask))
        XCTAssertFalse(LowZoomOverviewFade.isFootprintFadeBand(mask: 4))
        XCTAssertFalse(LowZoomOverviewFade.isFootprintFadeBand(mask: LowZoomOverviewFade.classFadeMask(startZoom: 5)))
    }

    /// The building fills leave the opaque pass while the fade is on: each
    /// polygon has its own alpha.
    func testTheFootprintBandIsOpaqueOnlyWithTheFadeOff() {
        var uniform = TileOverviewFadeUniform(overviewAlpha: 1, roadAlpha: 1, landuseAlpha: 1, pixelsPerPoint: 2, cameraZoom: 15)
        XCTAssertTrue(TileStyleFadeMath.fadeIsOne(mask: LowZoomOverviewFade.footprintFadeMask, overviewFade: uniform))
        uniform.footprintOpaqueAreaPx = 2500
        XCTAssertFalse(TileStyleFadeMath.fadeIsOne(mask: LowZoomOverviewFade.footprintFadeMask, overviewFade: uniform))
        XCTAssertFalse(TileStyleFadeMath.fadeIsZero(mask: LowZoomOverviewFade.footprintFadeMask, overviewFade: uniform))
    }

    func testTheThresholdsAreTheDebugPanels() {
        let controls = DebugOverlayControlState()
        XCTAssertEqual(controls.snapshot().buildingGoneAreaPixels, BuildingFootprintFade.defaultGoneAreaPixels)
        XCTAssertEqual(controls.snapshot().buildingOpaqueAreaPixels, BuildingFootprintFade.defaultOpaqueAreaPixels)
        // The thresholds ride with the rule set a frame's zoom falls in.
        var sets = RingRuleSets.default
        sets.sets[1].tuning.buildingGoneAreaPixels = 300
        sets.sets[1].tuning.buildingOpaqueAreaPixels = 2000
        controls.setRingRuleSets(sets)
        let street = controls.snapshot(forTargetZoom: RingRuleSets.defaultStreetFirstZoom)
        XCTAssertEqual(street.buildingGoneAreaPixels, 300)
        XCTAssertEqual(street.buildingOpaqueAreaPixels, 2000)
        XCTAssertEqual(controls.snapshot(forTargetZoom: 3).buildingGoneAreaPixels, BuildingFootprintFade.defaultGoneAreaPixels,
                       "the globe's set keeps its own")
    }
}

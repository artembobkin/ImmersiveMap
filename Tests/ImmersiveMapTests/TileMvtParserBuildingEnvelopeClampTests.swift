// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Covers `clampEnvelopeBuildingExtrusions`: the outer envelope (hull) of a
/// building modelled as parts is clamped down the chain of significant parts
/// that overlap in height, while a real building with roof decoration keeps its
/// full height. The cases come from central Moscow: the Four Seasons block (roof
/// slabs entirely above the envelope top: veto), the Spasskaya Tower and Saint
/// Basil's Cathedral (parts ending at the envelope top: clamped down the chain),
/// and a street canopy (a break in the chain, which must not drag the top down).
final class TileMvtParserBuildingEnvelopeClampTests: XCTestCase {
    private func makeParser() -> TileMvtParser {
        let config = ImmersiveMapSettings.default
        return TileMvtParser(
            determineFeatureStyle: DetermineFeatureStyle(mapStyle: ImmersiveMapTilesDefaultMapStyle()),
            labelProviderProfile: ImmersiveMapProviderRuntimeContext(settings: config).labelProviderProfile,
            config: config,
            glyphCoverage: .legacyAtlasForTests
        )
    }

    private func makeCandidate(buildingId: UInt64,
                               exterior: [SIMD2<Float>],
                               baseHeight: Float,
                               topHeight: Float) -> TileMvtParser.BuildingExtrusionCandidate {
        let signature = TileMvtParser.BuildingFootprintSignature(
            exterior: exterior.map { UInt64(UInt32(bitPattern: Int32($0.x.rounded()))) << 32
                | UInt64(UInt32(bitPattern: Int32($0.y.rounded()))) },
            interiors: []
        )
        let roofVertices = exterior.map { SIMD2<Int16>(Int16($0.x.rounded()), Int16($0.y.rounded())) }
        return TileMvtParser.BuildingExtrusionCandidate(
            styleKey: 1,
            buildingId: buildingId,
            footprintSignature: signature,
            clippedExterior: exterior,
            clippedInteriors: [],
            rawExterior: exterior,
            hasRawInteriorRings: false,
            roof: TileMvtParser.ParsedPolygon(vertices: roofVertices, indices: [0, 1, 2]),
            roofInfo: nil,
            baseHeight: baseHeight,
            topHeight: topHeight
        )
    }

    private func square(x: Float, y: Float, size: Float) -> [SIMD2<Float>] {
        [SIMD2(x, y), SIMD2(x + size, y), SIMD2(x + size, y + size), SIMD2(x, y + size)]
    }

    private func resolvedTop(of buildingId: UInt64,
                             in resolved: [TileMvtParser.BuildingExtrusionCandidate]) -> Float? {
        resolved.first { $0.buildingId == buildingId }?.topHeight
    }

    func testHullEnvelopeIsClampedDownThePartChain() {
        let parser = makeParser()
        var candidates = [makeCandidate(buildingId: 1,
                                        exterior: square(x: 0, y: 0, size: 100),
                                        baseHeight: 0,
                                        topHeight: 60)]
        // Four quadrant parts reach the top of the envelope (the hull), so the
        // chain walks down to their base.
        for (index, origin) in [SIMD2<Float>(0, 0), SIMD2(50, 0), SIMD2(0, 50), SIMD2(50, 50)].enumerated() {
            candidates.append(makeCandidate(buildingId: UInt64(10 + index),
                                            exterior: square(x: origin.x, y: origin.y, size: 50),
                                            baseHeight: 12,
                                            topHeight: 55))
        }

        let resolved = parser.resolveExteriorBuildingExtrusions(candidates)

        XCTAssertEqual(resolvedTop(of: 1, in: resolved), 12)
    }

    func testDisconnectedLowCanopyDoesNotDragTheClampDown() {
        let parser = makeParser()
        var candidates = [makeCandidate(buildingId: 1,
                                        exterior: square(x: 0, y: 0, size: 100),
                                        baseHeight: 0,
                                        topHeight: 60)]
        // Significant roof parts form a chain near the top...
        for (index, origin) in [SIMD2<Float>(0, 0), SIMD2(50, 0), SIMD2(0, 50), SIMD2(50, 50)].enumerated() {
            candidates.append(makeCandidate(buildingId: UInt64(10 + index),
                                            exterior: square(x: origin.x, y: origin.y, size: 40),
                                            baseHeight: 50,
                                            topHeight: 58))
        }
        // ...while a significant street canopy hangs with a gap in height below
        // them: before the fix it was the one setting the clamp level, leaving a
        // two-metre stump.
        candidates.append(makeCandidate(buildingId: 20,
                                        exterior: square(x: 30, y: 30, size: 30),
                                        baseHeight: 4,
                                        topHeight: 8))

        let resolved = parser.resolveExteriorBuildingExtrusions(candidates)

        XCTAssertEqual(resolvedTop(of: 1, in: resolved), 50)
    }

    func testRooftopPartsAboveEnvelopeTopVetoTheClamp() {
        let parser = makeParser()
        var candidates = [makeCandidate(buildingId: 1,
                                        exterior: square(x: 0, y: 0, size: 100),
                                        baseHeight: 0,
                                        topHeight: 60)]
        // A real building: significant roof slabs and lanterns sit entirely
        // ABOVE the envelope top (the Four Seasons case). Clamping is vetoed,
        // otherwise the body of the building would vanish and its decoration
        // would hang in the air.
        for (index, origin) in [SIMD2<Float>(0, 0), SIMD2(50, 0), SIMD2(0, 50), SIMD2(50, 50)].enumerated() {
            candidates.append(makeCandidate(buildingId: UInt64(10 + index),
                                            exterior: square(x: origin.x, y: origin.y, size: 40),
                                            baseHeight: 62,
                                            topHeight: 66))
        }
        // The veto holds even with low significant parts inside the envelope.
        candidates.append(makeCandidate(buildingId: 20,
                                        exterior: square(x: 10, y: 10, size: 40),
                                        baseHeight: 8,
                                        topHeight: 40))

        let resolved = parser.resolveExteriorBuildingExtrusions(candidates)

        XCTAssertEqual(resolvedTop(of: 1, in: resolved), 60)
    }

    func testTinyDecorativePartsAreIgnored() {
        let parser = makeParser()
        var candidates = [makeCandidate(buildingId: 1,
                                        exterior: square(x: 0, y: 0, size: 100),
                                        baseHeight: 0,
                                        topHeight: 60)]
        // Four tiny structures (chimneys, dormers): about 1% of the footprint in
        // total, so they count neither as witnesses nor as a veto.
        for (index, origin) in [SIMD2<Float>(10, 10), SIMD2(80, 10), SIMD2(10, 80), SIMD2(80, 80)].enumerated() {
            candidates.append(makeCandidate(buildingId: UInt64(10 + index),
                                            exterior: square(x: origin.x, y: origin.y, size: 5),
                                            baseHeight: index == 0 ? 4 : 50,
                                            topHeight: index == 0 ? 8 : 58))
        }

        let resolved = parser.resolveExteriorBuildingExtrusions(candidates)

        XCTAssertEqual(resolvedTop(of: 1, in: resolved), 60)
    }

    func testEnvelopeWithFewerThanFourPartsKeepsFullHeight() {
        let parser = makeParser()
        var candidates = [makeCandidate(buildingId: 1,
                                        exterior: square(x: 0, y: 0, size: 100),
                                        baseHeight: 0,
                                        topHeight: 60)]
        for (index, origin) in [SIMD2<Float>(0, 0), SIMD2(50, 0), SIMD2(0, 50)].enumerated() {
            candidates.append(makeCandidate(buildingId: UInt64(10 + index),
                                            exterior: square(x: origin.x, y: origin.y, size: 50),
                                            baseHeight: 12,
                                            topHeight: 55))
        }

        let resolved = parser.resolveExteriorBuildingExtrusions(candidates)

        XCTAssertEqual(resolvedTop(of: 1, in: resolved), 60)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class VectorTileLabelGlyphCoverageTests: XCTestCase {
    func testCoverageAllowsOnlyGlyphsPresentInAtlas() {
        let coverage = VectorTileLabelGlyphCoverage(supportedScalars: [65, 66, 32])

        XCTAssertTrue(coverage.canRender("A B"))
        XCTAssertFalse(coverage.canRender("AC"))
    }

    func testExplicitCoverageAllowsLayoutControlsOutsideGlyphSet() {
        let coverage = VectorTileLabelGlyphCoverage(supportedScalars: [65])

        XCTAssertTrue(coverage.canRender("A\nA"))
        XCTAssertTrue(coverage.canRender("A\tA"))
        XCTAssertTrue(coverage.canRender("A\rA"))
        XCTAssertTrue(coverage.canRender("A\u{00A0}A"))
    }

    func testCoverageCombinesBoldAndThinAtlasGlyphs() {
        let bold = AtlasData.testAtlas(glyphs: [65])
        let thin = AtlasData.testAtlas(glyphs: [66])

        let coverage = VectorTileLabelGlyphCoverage(atlasData: bold, thinAtlasData: thin)

        XCTAssertTrue(coverage.canRender("AB"))
        XCTAssertFalse(coverage.canRender("ABC"))
    }

    func testAtlasCoverageAllowsLayoutControlsOutsideGlyphSet() {
        let bold = AtlasData.testAtlas(glyphs: [65])
        let thin = AtlasData.testAtlas(glyphs: [])

        let coverage = VectorTileLabelGlyphCoverage(atlasData: bold, thinAtlasData: thin)

        XCTAssertTrue(coverage.canRender("A A\nA\rA\tA"))
    }

    func testAtlasCoverageRejectsUnsupportedNonWhitespaceScalar() {
        let bold = AtlasData.testAtlas(glyphs: [65])
        let thin = AtlasData.testAtlas(glyphs: [])

        let coverage = VectorTileLabelGlyphCoverage(atlasData: bold, thinAtlasData: thin)

        XCTAssertFalse(coverage.canRender("AЖA"))
    }

    func testLegacyAtlasForTestsRejectsUnsupportedJapaneseText() {
        XCTAssertFalse(VectorTileLabelGlyphCoverage.legacyAtlasForTests.canRender("東京"))
    }

    func testBundledAtlasCoverageIncludesEuropeanAndCyrillicMapGlyphs() throws {
        let boldAtlas = try Self.loadBundledAtlas(named: "atlas")
        let thinAtlas = try Self.loadBundledAtlas(named: "atlas_thin")
        let coverage = VectorTileLabelGlyphCoverage(atlasData: boldAtlas, thinAtlasData: thinAtlas)

        XCTAssertTrue(coverage.canRender("Océan Atlantique"))
        XCTAssertTrue(coverage.canRender("Südlicher Ozean"))
        XCTAssertTrue(coverage.canRender("Océano Atlántico"))
        XCTAssertTrue(coverage.canRender("São Paulo"))
        XCTAssertTrue(coverage.canRender("İstanbul"))
        XCTAssertTrue(coverage.canRender("Северный Ледовитый океан"))
    }

    func testBundledAtlasesUseMtsdfTriplePrecisionDistanceRange() throws {
        let boldAtlas = try Self.loadBundledAtlas(named: "atlas")
        let thinAtlas = try Self.loadBundledAtlas(named: "atlas_thin")

        XCTAssertEqual(boldAtlas.atlas.type, "mtsdf")
        XCTAssertEqual(thinAtlas.atlas.type, "mtsdf")
        XCTAssertEqual(boldAtlas.atlas.distanceRange, 24)
        XCTAssertEqual(thinAtlas.atlas.distanceRange, 24)
    }

    private static func loadBundledAtlas(named name: String) throws -> AtlasData {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AtlasData.self, from: data)
    }
}

private extension AtlasData {
    static func testAtlas(glyphs unicodes: [UInt32]) -> AtlasData {
        AtlasData(
            atlas: AtlasInfo(type: "msdf",
                             distanceRange: 8,
                             distanceRangeMiddle: 0,
                             size: 64,
                             width: 64,
                             height: 64,
                             yOrigin: "bottom"),
            metrics: Metrics(emSize: 1,
                             lineHeight: 1,
                             ascender: 1,
                             descender: 0,
                             underlineY: 0,
                             underlineThickness: 0),
            glyphs: unicodes.map { Glyph(unicode: $0, advance: 1, planeBounds: nil, atlasBounds: nil) }
        )
    }
}

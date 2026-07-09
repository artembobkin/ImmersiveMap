// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class PreparedTileDiskCodecTests: XCTestCase {
    func testPreparedTileCacheFormatVersionIncludesLabelVisibilityPolicyRevision() {
        XCTAssertEqual(PreparedTileDiskCaching.preparedFormatVersion, 21)
    }

    func testPreparedTileCodecRoundTripsArbitraryLabelLanguageMetadata() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let labelLanguage = ImmersiveMapSettings.LabelLanguage("pt-BR")
        let cacheIdentity = makeCacheIdentity(labelLanguage: labelLanguage)
        let preparedTile = makePreparedTile(tile: tile)

        let data = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                    cacheIdentity: cacheIdentity)
        let decoded = try PreparedTileDiskCodec.decode(data: data,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity)

        XCTAssertEqual(decoded.tile, tile)
    }

    func testPreparedTileCodecRoundTripsTextLabelDetailTiers() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .portuguese)
        let textLabels = PreparedTileCPU.TextLabels(full: makeTextLabelSet(seed: 1),
                                                    reduced: makeTextLabelSet(seed: 2),
                                                    minimal: makeTextLabelSet(seed: 3))
        let preparedTile = makePreparedTile(tile: tile, textLabels: textLabels)

        let data = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                    cacheIdentity: cacheIdentity)
        let decoded = try PreparedTileDiskCodec.decode(data: data,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity)

        assertTextLabelSet(decoded.textLabels.full, equals: textLabels.full)
        assertTextLabelSet(decoded.textLabels.reduced, equals: textLabels.reduced)
        assertTextLabelSet(decoded.textLabels.minimal, equals: textLabels.minimal)
    }

    func testPreparedTileCodecRejectsMismatchedLabelLanguageMetadata() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let data = try PreparedTileDiskCodec.encode(
            preparedTile: makePreparedTile(tile: tile),
            cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese)
        )

        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: makeCacheIdentity(labelLanguage: .english))
        ) { error in
            XCTAssertTrue(error is PreparedTileDiskCodecError)
        }
    }

    func testPreparedTileCodecKeysOnSourceETag() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .portuguese)
        let data = try PreparedTileDiskCodec.encode(
            preparedTile: makePreparedTile(tile: tile),
            cacheIdentity: cacheIdentity,
            sourceETag: "etag-A"
        )

        // Matching ETag -> reused without re-parsing.
        let matched = try PreparedTileDiskCodec.decode(data: data,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       expectedSourceETag: "etag-A")
        XCTAssertEqual(matched.tile, tile)

        // Different ETag (server content changed at the same URL) -> rejected.
        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: cacheIdentity,
                                             expectedSourceETag: "etag-B")
        ) { error in
            XCTAssertTrue(error is PreparedTileDiskCodecError)
        }

        // nil expected ETag (offline fallback) -> accepted regardless of stored ETag.
        let anyETag = try PreparedTileDiskCodec.decode(data: data,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       expectedSourceETag: nil)
        XCTAssertEqual(anyETag.tile, tile)
    }

    func testPreparedTileCodecRejectsMismatchedTextRevisionMetadata() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let data = try PreparedTileDiskCodec.encode(
            preparedTile: makePreparedTile(tile: tile),
            cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese, textRevision: 5)
        )

        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese,
                                                                              textRevision: 6))
        ) { error in
            XCTAssertTrue(error is PreparedTileDiskCodecError)
        }
    }

    func testPreparedTileCodecRejectsMismatchedLabelFallbackPolicyMetadata() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let data = try PreparedTileDiskCodec.encode(
            preparedTile: makePreparedTile(tile: tile),
            cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese, fallbackPolicy: .international)
        )

        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese,
                                                                              fallbackPolicy: .localFirst))
        ) { error in
            XCTAssertTrue(error is PreparedTileDiskCodecError)
        }
    }

    private func makeCacheIdentity(labelLanguage: ImmersiveMapSettings.LabelLanguage,
                                   fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy = .international,
                                   textRevision: UInt32 = 4) -> PreparedTileCacheIdentity {
        PreparedTileCacheIdentity(preparedFormatVersion: PreparedTileDiskCaching.preparedFormatVersion,
                                  styleRevision: 1,
                                  tileSourceRevision: 2,
                                  flatSeparateRoadRenderingMinimumZoom: 3,
                                  textRevision: textRevision,
                                  labelLanguage: labelLanguage,
                                  labelFallbackPolicy: fallbackPolicy,
                                  houseNumbersEnabled: true,
                                  houseNumbersMinimumZoom: 15,
                                  capitalMaximumZoom: 12,
                                  cityMaximumZoom: 12,
                                  smallSettlementMaximumZoom: 12,
                                  landmarkMinimumZoom: 13,
                                  addTestBorders: false)
    }

    private func makePreparedTile(tile: Tile,
                                  textLabels: PreparedTileCPU.TextLabels? = nil) -> PreparedTileCPU {
        let emptyGeometry = PreparedTileCPU.GeometryLayer(vertices: [],
                                                         indices: [],
                                                         styles: [],
                                                         overviewStyleMasks: [])
        let emptyRoadPhases = RoadGeometryPhases(shadow: emptyGeometry,
                                                 casing: emptyGeometry,
                                                 fill: emptyGeometry,
                                                 detail: emptyGeometry,
                                                 overlay: emptyGeometry)

        return PreparedTileCPU(tile: tile,
                               ground: emptyGeometry,
                               roads: RoadStructureBuckets(tunnel: emptyRoadPhases,
                                                          ground: emptyRoadPhases,
                                                          bridge: emptyRoadPhases),
                               bridgeOverlay: emptyGeometry,
                               extruded: PreparedTileCPU.Extruded(vertices: [],
                                                                  indices: [],
                                                                  styles: []),
                               textLabels: textLabels ?? PreparedTileCPU.TextLabels(full: emptyTextLabelSet(),
                                                                                    reduced: emptyTextLabelSet(),
                                                                                    minimal: emptyTextLabelSet()),
                               roadLabels: PreparedTileCPU.RoadLabels(pathInputs: [],
                                                                      pathRanges: [],
                                                                      pathLabels: [],
                                                                      labelStyle: nil,
                                                                      localGlyphVertices: [],
                                                                      glyphBounds: [],
                                                                      glyphBoundRanges: [],
                                                                      sizes: [],
                                                                      anchorRanges: [],
                                                                      anchors: []))
    }

    private func emptyTextLabelSet() -> PreparedTileCPU.TextLabelSet {
        PreparedTileCPU.TextLabelSet(placementInputs: [],
                                     glyphRuns: [],
                                     poiIconRuns: [])
    }

    private func makeTextLabelSet(seed: Int32) -> PreparedTileCPU.TextLabelSet {
        let placementInput = TextLabelPlacementInput(
            pointInput: TilePointInput(uv: SIMD2<Float>(Float(seed) + 0.1, Float(seed) + 0.2),
                                       tile: SIMD3<Int32>(seed, seed + 1, seed + 2),
                                       tileSlotIndex: UInt32(seed + 10)),
            placementMeta: LabelPlacementMeta(key: UInt64(seed + 100),
                                              sortKey: Int(seed + 200),
                                              collisionPriority: Int(seed + 300),
                                              labelSizePx: SIMD2<Float>(Float(seed) + 10.1, Float(seed) + 20.2))
        )
        let glyphVertex = makeLabelVertex(seed: seed, labelIndex: seed + 400, spriteSeed: 0)
        let poiIconVertex = makeLabelVertex(seed: seed + 10, labelIndex: seed + 500, spriteSeed: seed + 20)

        return PreparedTileCPU.TextLabelSet(
            placementInputs: [placementInput],
            glyphRuns: [PreparedTileCPU.TextGlyphRun(style: makeLabelTextStyle(seed: seed),
                                                     localGlyphVertices: [glyphVertex])],
            poiIconRuns: [PreparedTileCPU.PoiIconRun(style: makeLabelTextStyle(seed: seed + 30),
                                                     localIconVertices: [poiIconVertex])]
        )
    }

    private func makeLabelTextStyle(seed: Int32) -> LabelTextStyle {
        LabelTextStyle(key: Int(seed + 600),
                       fillColor: SIMD3<Float>(Float(seed) + 0.01, Float(seed) + 0.02, Float(seed) + 0.03),
                       strokeColor: SIMD3<Float>(Float(seed) + 0.04, Float(seed) + 0.05, Float(seed) + 0.06),
                       strokeWidthPx: Float(seed) + 1.5,
                       sizePx: Float(seed) + 12.5,
                       weight: seed.isMultiple(of: 2) ? .thin : .bold)
    }

    private func makeLabelVertex(seed: Int32, labelIndex: Int32, spriteSeed: Int32) -> LabelVertex {
        LabelVertex(position: SIMD2<Float>(Float(seed) + 1.1, Float(seed) + 1.2),
                    uv: SIMD2<Float>(Float(seed) + 2.1, Float(seed) + 2.2),
                    labelIndex: labelIndex,
                    spriteUV: SIMD2<Float>(Float(spriteSeed) + 3.1, Float(spriteSeed) + 3.2))
    }

    private func assertTextLabelSet(_ actual: PreparedTileCPU.TextLabelSet,
                                    equals expected: PreparedTileCPU.TextLabelSet,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        XCTAssertEqual(actual.placementInputs.count, expected.placementInputs.count, file: file, line: line)
        XCTAssertEqual(actual.glyphRuns.count, expected.glyphRuns.count, file: file, line: line)
        XCTAssertEqual(actual.poiIconRuns.count, expected.poiIconRuns.count, file: file, line: line)
        guard actual.placementInputs.isEmpty == false,
              actual.glyphRuns.isEmpty == false,
              actual.poiIconRuns.isEmpty == false else {
            return
        }
        XCTAssertEqual(actual.glyphRuns[0].localGlyphVertices.count,
                       expected.glyphRuns[0].localGlyphVertices.count,
                       file: file,
                       line: line)
        XCTAssertEqual(actual.poiIconRuns[0].localIconVertices.count,
                       expected.poiIconRuns[0].localIconVertices.count,
                       file: file,
                       line: line)
        guard actual.glyphRuns[0].localGlyphVertices.isEmpty == false,
              actual.poiIconRuns[0].localIconVertices.isEmpty == false else {
            return
        }

        assertPlacementInput(actual.placementInputs[0], equals: expected.placementInputs[0], file: file, line: line)
        assertLabelTextStyle(actual.glyphRuns[0].style, equals: expected.glyphRuns[0].style, file: file, line: line)
        assertLabelVertex(actual.glyphRuns[0].localGlyphVertices[0],
                          equals: expected.glyphRuns[0].localGlyphVertices[0],
                          file: file,
                          line: line)
        assertLabelTextStyle(actual.poiIconRuns[0].style,
                             equals: expected.poiIconRuns[0].style,
                             file: file,
                             line: line)
        assertLabelVertex(actual.poiIconRuns[0].localIconVertices[0],
                          equals: expected.poiIconRuns[0].localIconVertices[0],
                          file: file,
                          line: line)
    }

    private func assertPlacementInput(_ actual: TextLabelPlacementInput,
                                      equals expected: TextLabelPlacementInput,
                                      file: StaticString,
                                      line: UInt) {
        XCTAssertEqual(actual.pointInput.uv, expected.pointInput.uv, file: file, line: line)
        XCTAssertEqual(actual.pointInput.tile, expected.pointInput.tile, file: file, line: line)
        XCTAssertEqual(actual.pointInput.tileSlotIndex, expected.pointInput.tileSlotIndex, file: file, line: line)
        XCTAssertEqual(actual.placementMeta.key, expected.placementMeta.key, file: file, line: line)
        XCTAssertEqual(actual.placementMeta.sortKey, expected.placementMeta.sortKey, file: file, line: line)
        XCTAssertEqual(actual.placementMeta.collisionPriority,
                       expected.placementMeta.collisionPriority,
                       file: file,
                       line: line)
        XCTAssertEqual(actual.placementMeta.labelSizePx, expected.placementMeta.labelSizePx, file: file, line: line)
    }

    private func assertLabelTextStyle(_ actual: LabelTextStyle,
                                      equals expected: LabelTextStyle,
                                      file: StaticString,
                                      line: UInt) {
        XCTAssertEqual(actual.key, expected.key, file: file, line: line)
        XCTAssertEqual(actual.fillColor, expected.fillColor, file: file, line: line)
        XCTAssertEqual(actual.strokeColor, expected.strokeColor, file: file, line: line)
        XCTAssertEqual(actual.strokeWidthPx, expected.strokeWidthPx, file: file, line: line)
        XCTAssertEqual(actual.sizePx, expected.sizePx, file: file, line: line)
        XCTAssertEqual(actual.weight, expected.weight, file: file, line: line)
    }

    private func assertLabelVertex(_ actual: LabelVertex,
                                   equals expected: LabelVertex,
                                   file: StaticString,
                                   line: UInt) {
        XCTAssertEqual(actual.position, expected.position, file: file, line: line)
        XCTAssertEqual(actual.uv, expected.uv, file: file, line: line)
        XCTAssertEqual(actual.labelIndex, expected.labelIndex, file: file, line: line)
        XCTAssertEqual(actual.spriteUV, expected.spriteUV, file: file, line: line)
    }
}

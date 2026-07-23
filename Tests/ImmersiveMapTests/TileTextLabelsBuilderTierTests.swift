// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class TileTextLabelsBuilderTierTests: XCTestCase {
    func testTierPolicyKeepsAnchorsDegradesMinorPoiAndDropsFarPoi() {
        // 2 якоря, крупный POI (рампа 13), мелкий иконочный POI (рампа 16),
        // мелкий безыконный POI и номер дома.
        let anchorA = makeBuiltLabel(index: 0, key: 1)
        let anchorB = makeBuiltLabel(index: 1, key: 1)
        let majorPoi = makeBuiltLabel(index: 2,
                                      key: 2,
                                      detailCategory: .poi,
                                      minCameraZoom: 13,
                                      withIcon: true)
        let minorIconPoi = makeBuiltLabel(index: 3,
                                          key: 2,
                                          detailCategory: .poi,
                                          minCameraZoom: 16,
                                          withIcon: true)
        let minorIconlessPoi = makeBuiltLabel(index: 4,
                                              key: 2,
                                              detailCategory: .poi,
                                              minCameraZoom: 16)
        let houseNumber = makeBuiltLabel(index: 5,
                                         key: 3,
                                         detailCategory: .housenumber)
        let labels = [anchorA, anchorB, majorPoi, minorIconPoi, minorIconlessPoi, houseNumber]

        let result = TileTextLabelsBuilder.makeTextLabels(from: labels)

        XCTAssertEqual(result.full.placementInputs.count, 6)

        // Reduced: якоря и крупный POI целиком, мелкий иконочный деградирует
        // до иконки (коллизионный бокс равен квадрату иконки), безыконный и
        // номер дома выпадают.
        XCTAssertEqual(result.reduced.placementInputs.map { $0.placementMeta.key },
                       [UInt64(1), UInt64(2), UInt64(3), UInt64(4)])
        let degraded = result.reduced.placementInputs[3]
        XCTAssertEqual(degraded.placementMeta.labelSizePx, minorIconPoi.iconOnlySizePx)
        let reducedGlyphIndices = Set(result.reduced.glyphRuns.flatMap { $0.localGlyphVertices }.map { Int($0.labelIndex) })
        XCTAssertFalse(reducedGlyphIndices.contains(3), "Икон-only лейбл не должен нести текстовые вершины")
        let reducedIconIndices = Set(result.reduced.poiIconRuns.flatMap { $0.localIconVertices }.map { Int($0.labelIndex) })
        XCTAssertTrue(reducedIconIndices.contains(3), "Икон-only лейбл обязан нести вершины иконки")

        // Minimal: только якоря в пределах бюджета, никаких POI и номеров домов.
        XCTAssertEqual(result.minimal.placementInputs.map { $0.placementMeta.key },
                       [UInt64(1), UInt64(2)])
    }

    func testAbsoluteBudgetsCapDenseTiles() {
        // Плотный тайл: 20 якорей и 15 мелких иконочных POI. Бюджеты
        // абсолютные: средний тир берёт верх каждой группы, дальний - только
        // горстку якорей.
        let anchors = (0..<20).map { makeBuiltLabel(index: $0, key: 1) }
        let pois = (20..<35).map {
            makeBuiltLabel(index: $0,
                           key: 2,
                           detailCategory: .poi,
                           minCameraZoom: 16,
                           withIcon: true)
        }

        let result = TileTextLabelsBuilder.makeTextLabels(from: anchors + pois)

        XCTAssertEqual(result.full.placementInputs.count, 35)
        XCTAssertEqual(result.reduced.placementInputs.count, 24)
        XCTAssertEqual(result.reduced.placementInputs.prefix(12).map { $0.placementMeta.key },
                       (1...12).map { UInt64($0) },
                       "Бюджет якорей забирают первые по приоритету")
        XCTAssertEqual(result.reduced.placementInputs.suffix(12).map { $0.placementMeta.key },
                       (21...32).map { UInt64($0) },
                       "Бюджет POI забирают лучшие по рангу")
        XCTAssertEqual(result.minimal.placementInputs.count, 4)
    }

    func testTierVerticesUseCompactLabelIndices() {
        let labels = (0..<11).map { makeBuiltLabel(index: $0, key: 1) }
        let result = TileTextLabelsBuilder.makeTextLabels(from: labels)
        let minimalIndices = Set(result.minimal.glyphRuns.flatMap { $0.localGlyphVertices }.map { Int($0.labelIndex) })

        XCTAssertEqual(minimalIndices, [0, 1, 2, 3])
    }

    func testLabelsSharingKeyButDifferingWeightSplitIntoSeparateRuns() throws {
        // Providers (OpenMapTiles/OSM) reuse one style key across weights, e.g. key 70
        // for bold cities and thin towns. Bold and thin glyphs are built against different
        // atlas textures, so a run may bind only one texture. Merging them into one run
        // by key alone made the other weight's glyphs sample the wrong atlas (garbled text).
        let boldLabel = makeBuiltLabel(index: 0,
                                       key: 70,
                                       weight: .bold,
                                       fillColor: SIMD3<Float>(0.2, 0.2, 0.2),
                                       uv: SIMD2<Float>(0.1, 0.1))
        let thinLabel = makeBuiltLabel(index: 1,
                                       key: 70,
                                       weight: .thin,
                                       fillColor: SIMD3<Float>(0.3, 0.3, 0.3),
                                       uv: SIMD2<Float>(0.9, 0.9))

        let result = TileTextLabelsBuilder.makeTextLabels(from: [boldLabel, thinLabel])
        let runs = result.full.glyphRuns

        XCTAssertEqual(runs.count, 2, "Same key with mixed weights must not collapse into one run")

        let boldRun = try XCTUnwrap(runs.first { $0.style.weight == .bold })
        let thinRun = try XCTUnwrap(runs.first { $0.style.weight == .thin })

        // Each run must carry only the glyphs built for its own weight/atlas.
        XCTAssertEqual(boldRun.localGlyphVertices.map { $0.uv }, [SIMD2<Float>(0.1, 0.1)])
        XCTAssertEqual(thinRun.localGlyphVertices.map { $0.uv }, [SIMD2<Float>(0.9, 0.9)])
        XCTAssertEqual(boldRun.style.fillColor, SIMD3<Float>(0.2, 0.2, 0.2))
        XCTAssertEqual(thinRun.style.fillColor, SIMD3<Float>(0.3, 0.3, 0.3))
    }

    private func makeBuiltLabel(index: Int,
                                key: Int,
                                weight: LabelFontWeight = .thin,
                                fillColor: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                                uv: SIMD2<Float> = .zero,
                                detailCategory: VectorTileLabelDetailCategory = .anchor,
                                minCameraZoom: Float = 0,
                                withIcon: Bool = false) -> TileTextLabelsBuilder.BuiltBaseLabel {
        let style = LabelTextStyle(key: key,
                                   fillColor: fillColor,
                                   strokeColor: SIMD3<Float>(1, 1, 1),
                                   strokeWidthPx: 2,
                                   sizePx: 20,
                                   weight: weight)
        let iconVertex = LabelVertex(position: SIMD2<Float>(0, 0),
                                     uv: SIMD2<Float>(0.5, 0.5),
                                     labelIndex: simd_int1(index),
                                     spriteUV: SIMD2<Float>(0, 0))
        return TileTextLabelsBuilder.BuiltBaseLabel(
            placementInput: TextLabelPlacementInput(
                pointInput: TilePointInput(uv: SIMD2<Float>(Float(index), Float(index)),
                                           tile: SIMD3<Int32>(1, 2, 4),
                                           tileSlotIndex: 0),
                placementMeta: LabelPlacementMeta(key: UInt64(index + 1),
                                                  sortKey: index,
                                                  collisionPriority: index,
                                                  labelSizePx: SIMD2<Float>(10, 4),
                                                  minCameraZoom: minCameraZoom)
            ),
            style: style,
            textVertices: [
                LabelVertex(position: SIMD2<Float>(0, 0),
                            uv: uv,
                            labelIndex: simd_int1(index),
                            spriteUV: SIMD2<Float>(0, 0))
            ],
            iconVertices: withIcon ? [iconVertex] : [],
            detailCategory: detailCategory,
            iconOnlyVertices: withIcon ? [iconVertex] : [],
            iconOnlySizePx: withIcon ? SIMD2<Float>(24, 24) : .zero
        )
    }
}

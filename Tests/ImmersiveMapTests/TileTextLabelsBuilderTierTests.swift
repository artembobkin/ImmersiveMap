// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class TileTextLabelsBuilderTierTests: XCTestCase {
    func testBuildCreatesFullReducedAndMinimalSetsByPriority() {
        let result = TileTextLabelsBuilder.makeTextLabels(from: makeBuiltLabels(count: 11))

        XCTAssertEqual(result.full.placementInputs.count, 11)
        XCTAssertEqual(result.reduced.placementInputs.count, 6)
        XCTAssertEqual(result.minimal.placementInputs.count, 2)
        XCTAssertEqual(result.reduced.placementInputs.map { $0.placementMeta.key }, Array(UInt64(1)...UInt64(6)))
        XCTAssertEqual(result.minimal.placementInputs.map { $0.placementMeta.key }, [UInt64(1), UInt64(2)])
    }

    func testTierVerticesUseCompactLabelIndices() {
        let result = TileTextLabelsBuilder.makeTextLabels(from: makeBuiltLabels(count: 11))
        let minimalIndices = Set(result.minimal.glyphRuns.flatMap { $0.localGlyphVertices }.map { Int($0.labelIndex) })

        XCTAssertEqual(minimalIndices, [0, 1])
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
                                weight: LabelFontWeight,
                                fillColor: SIMD3<Float>,
                                uv: SIMD2<Float>) -> TileTextLabelsBuilder.BuiltBaseLabel {
        let style = LabelTextStyle(key: key,
                                   fillColor: fillColor,
                                   strokeColor: SIMD3<Float>(1, 1, 1),
                                   strokeWidthPx: 2,
                                   sizePx: 20,
                                   weight: weight)
        return TileTextLabelsBuilder.BuiltBaseLabel(
            placementInput: TextLabelPlacementInput(
                pointInput: TilePointInput(uv: SIMD2<Float>(Float(index), Float(index)),
                                           tile: SIMD3<Int32>(1, 2, 4),
                                           tileSlotIndex: 0),
                placementMeta: LabelPlacementMeta(key: UInt64(index + 1),
                                                  sortKey: index,
                                                  collisionPriority: index,
                                                  labelSizePx: SIMD2<Float>(10, 4))
            ),
            style: style,
            textVertices: [
                LabelVertex(position: SIMD2<Float>(0, 0),
                            uv: uv,
                            labelIndex: simd_int1(index),
                            spriteUV: SIMD2<Float>(0, 0))
            ],
            iconVertices: []
        )
    }

    private func makeBuiltLabels(count: Int) -> [TileTextLabelsBuilder.BuiltBaseLabel] {
        let style = LabelTextStyle(key: 1,
                                   fillColor: SIMD3<Float>(1, 1, 1),
                                   strokeColor: SIMD3<Float>(0, 0, 0),
                                   strokeWidthPx: 1,
                                   sizePx: 12,
                                   weight: .thin)
        return (0..<count).map { index in
            TileTextLabelsBuilder.BuiltBaseLabel(
                placementInput: TextLabelPlacementInput(
                    pointInput: TilePointInput(uv: SIMD2<Float>(Float(index), Float(index)),
                                               tile: SIMD3<Int32>(1, 2, 4),
                                               tileSlotIndex: 0),
                    placementMeta: LabelPlacementMeta(key: UInt64(index + 1),
                                                      sortKey: index,
                                                      collisionPriority: index,
                                                      labelSizePx: SIMD2<Float>(10, 4))
                ),
                style: style,
                textVertices: [
                    LabelVertex(position: SIMD2<Float>(0, 0),
                                uv: SIMD2<Float>(0, 0),
                                labelIndex: simd_int1(index),
                                spriteUV: SIMD2<Float>(0, 0))
                ],
                iconVertices: []
            )
        }
    }
}

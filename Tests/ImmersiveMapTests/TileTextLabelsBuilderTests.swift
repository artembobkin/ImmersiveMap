// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The tile's text labels are one set: every built label, in its
/// collision priority order, with compact label indices and one glyph run
/// per style identity.
final class TileTextLabelsBuilderTests: XCTestCase {
    func testEveryLabelIsKeptInOrder() {
        let labels = (0..<40).map { makeBuiltLabel(index: $0, key: $0 % 3 + 1, withIcon: $0 % 2 == 0) }

        let result = TileTextLabelsBuilder.makeTextLabels(from: labels)

        XCTAssertEqual(result.placementInputs.count, 40, "No budget and no tier: the tile carries all its labels")
        XCTAssertEqual(result.placementInputs.map { $0.placementMeta.key }, (0..<40).map { UInt64($0 + 1) })
        let glyphIndices = Set(result.glyphRuns.flatMap { $0.localGlyphVertices }.map { Int($0.labelIndex) })
        XCTAssertEqual(glyphIndices, Set(0..<40), "Every label has its text vertices, indexed compactly")
        let iconIndices = Set(result.poiIconRuns.flatMap { $0.localIconVertices }.map { Int($0.labelIndex) })
        XCTAssertEqual(iconIndices, Set(stride(from: 0, to: 40, by: 2)), "Icons ride with the labels that have them")
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
        let runs = result.glyphRuns

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
                                withIcon: Bool = false) -> TileTextLabelsBuilder.BuiltBaseLabel {
        let style = LabelTextStyle(key: key,
                                   fillColor: fillColor,
                                   strokeColor: SIMD3<Float>(1, 1, 1),
                                   haloEm: 0.15,
                                   sizePoints: 20,
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
                                                  labelSizePoints: SIMD2<Float>(10, 4),
                                                  minCameraZoom: 0)
            ),
            style: style,
            textVertices: [
                LabelVertex(position: SIMD2<Float>(0, 0),
                            uv: uv,
                            labelIndex: simd_int1(index),
                            spriteUV: SIMD2<Float>(0, 0))
            ],
            iconVertices: withIcon ? [iconVertex] : [])
    }
}

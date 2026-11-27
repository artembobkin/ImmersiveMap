// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// A label wraps at the base box to three lines; a name that does not fit
/// them re-wraps at a box one and a half times as wide and up to six lines,
/// instead of running its tail onto one long third line. Bakes through the
/// real `TextLayout`, over the atlases' metrics alone, with no GPU.
final class LabelWrapExtensionTests: XCTestCase {
    private let scale: Float = 14

    private func makeLayout() throws -> TextLayout {
        try TextLayout(metrics: GlyphAtlasMetrics(bundle: ImmersiveMapResourceBundle.bundle()))
    }

    private func metrics(_ text: String, layout: TextLayout) -> TextMetrics {
        TileTextLabelsBuilder.wrappedLabelMetrics(for: text,
                                                  labelIndex: 0,
                                                  textScale: scale,
                                                  weight: .bold,
                                                  textLayout: layout)
    }

    func testAShortNameStaysInTheBaseBox() throws {
        let layout = try makeLayout()
        let short = metrics("Кафедры анатомии", layout: layout)
        XCTAssertLessThanOrEqual(short.size.width, scale * 10.0 * 1.02,
                                 "A name that fits three lines keeps the base width")
    }

    func testALongNameGetsTheWiderTallerBoxInsteadOfATrailingLine() throws {
        let layout = try makeLayout()
        let long = metrics("Кафедры анатомии, гистологии, микробиологии академии им. И. М. Сеченова",
                           layout: layout)
        let baseWidth = scale * 10.0
        // The old behavior: three lines, the third running far past the box.
        // The new one: no line wider than the extended box.
        XCTAssertLessThanOrEqual(long.size.width, baseWidth * 1.5 * 1.02,
                                 "Every line fits the extended box")
        XCTAssertGreaterThan(long.size.width, baseWidth,
                             "and the box really did widen")
        // The extra room is in height as well: more than three lines tall.
        let threeLines = metrics("Кафедры\nанатомии\nгистологии", layout: layout).size.height
        XCTAssertGreaterThan(long.size.height, threeLines,
                             "A long name runs taller than three lines")
    }
}

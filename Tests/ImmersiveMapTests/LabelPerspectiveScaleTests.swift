// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// A point label's shrink for its distance rides to the label shaders in
/// the runtime meta, in what was padding.
final class LabelPerspectiveScaleTests: XCTestCase {
    /// The Metal mirror (`LabelRuntimeMeta.h`) reads the scale after the
    /// fade alpha, and the stride stays the one it reads.
    func testTheScaleKeepsTheRuntimeMetaLayout() {
        XCTAssertEqual(MemoryLayout<LabelRuntimeMeta>.stride, 24)
        XCTAssertEqual(MemoryLayout<LabelRuntimeMeta>.offset(of: \.perspectiveScale), 12)
    }

    /// A label nobody scales is its full size: the road labels, which share
    /// the meta, and a base label before its first projection.
    func testAnUnscaledLabelIsFullSize() {
        XCTAssertEqual(LabelRuntimeMeta(duplicate: 0, visibleTileIndex: 0).perspectiveScale, 1)
    }

    func testTheDefaultShrinksToHalf() {
        XCTAssertEqual(ImmersiveMapSettings.default.labels.base.perspectiveMinimumScale, 0.5)
    }
}

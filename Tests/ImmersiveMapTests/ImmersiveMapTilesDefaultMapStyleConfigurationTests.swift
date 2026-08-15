// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapTilesDefaultMapStyleConfigurationTests: XCTestCase {
    /// A recolor must change disk-cache identity, otherwise the map keeps drawing
    /// from prepared tiles baked with the old palette.
    func testCacheFingerprintChangesWithEveryPaletteGroup() {
        let base = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault

        let relabeled = base.labels { labels in
            labels.town.haloEm += 0.05
        }
        let relayered = base.layers { layers in
            layers.water = SIMD4<Float>(0.12, 0.34, 0.56, 1)
        }
        let refeatured = base.features { features in
            features.buildingFillColor = SIMD4<Float>(0.18, 0.19, 0.23, 1)
        }

        XCTAssertNotEqual(base.cacheFingerprint, relabeled.cacheFingerprint)
        XCTAssertNotEqual(base.cacheFingerprint, relayered.cacheFingerprint)
        XCTAssertNotEqual(base.cacheFingerprint, refeatured.cacheFingerprint)
    }

    /// `-0.0 == 0.0` is true, so two configurations that compare equal would
    /// otherwise hash differently and thrash the prepared-tile disk cache.
    func testCacheFingerprintCanonicalizesSignedZeroFloatValues() {
        let positiveZero = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
            .labels { labels in
                labels.town.haloEm = 0.0
            }
        let negativeZero = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
            .labels { labels in
                labels.town.haloEm = -0.0
            }

        XCTAssertEqual(positiveZero, negativeZero)
        XCTAssertEqual(positiveZero.cacheFingerprint, negativeZero.cacheFingerprint)
    }

    /// The raw values are written into the prepared-tile disk format
    /// (`PreparedTileDiskCodec`) and folded into the style fingerprint, so
    /// swapping them would render every cached label at the wrong weight.
    func testLabelFontWeightRawValuesAreStable() {
        XCTAssertEqual(LabelFontWeight.bold.rawValue, 0)
        XCTAssertEqual(LabelFontWeight.thin.rawValue, 1)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class MapboxDefaultMapStyleConfigurationTests: XCTestCase {
    func testDefaultInitializerMatchesStandardStyleTokens() {
        XCTAssertEqual(MapboxDefaultMapStyleConfiguration(), .mapboxDefault)
        XCTAssertEqual(MapboxDefaultMapStyleConfiguration.LabelStyles.standard,
                       MapboxDefaultMapStyleConfiguration.mapboxDefault.labels)
        XCTAssertEqual(MapboxDefaultMapStyleConfiguration.LayerStyles.standard,
                       MapboxDefaultMapStyleConfiguration.mapboxDefault.layers)
        XCTAssertEqual(MapboxDefaultMapStyleConfiguration.FeatureStyles.standard,
                       MapboxDefaultMapStyleConfiguration.mapboxDefault.features)
    }

    func testStandardStyleExposesCurrentDefaultDistrictLabelTokens() {
        let style = MapboxDefaultMapStyleConfiguration.mapboxDefault

        XCTAssertEqual(style.labels.district.fillColor, SIMD3<Float>(0.44, 0.43, 0.41))
        XCTAssertEqual(style.labels.district.strokeColor, SIMD3<Float>(1.0, 1.0, 1.0))
        XCTAssertEqual(style.labels.district.strokeWidthPx, 2.7, accuracy: 0.0001)
        XCTAssertEqual(style.labels.district.weight, .thin)
    }

    func testLabelUpdateReturnsModifiedCopyWithoutMutatingOriginal() {
        let original = MapboxDefaultMapStyleConfiguration.mapboxDefault
        let updated = original.labels { labels in
            labels.district.strokeWidthPx = 1.5
            labels.poi.strokeWidthPx = 4.0
        }

        XCTAssertEqual(original.labels.district.strokeWidthPx, 2.7, accuracy: 0.0001)
        XCTAssertEqual(original.labels.poi.strokeWidthPx, 7.2, accuracy: 0.0001)
        XCTAssertEqual(updated.labels.district.strokeWidthPx, 1.5, accuracy: 0.0001)
        XCTAssertEqual(updated.labels.poi.strokeWidthPx, 4.0, accuracy: 0.0001)
    }

    func testFeatureUpdateReturnsModifiedCopyWithoutMutatingOriginal() {
        let original = MapboxDefaultMapStyleConfiguration.mapboxDefault
        let updated = original.features { features in
            features.buildingFillColor = SIMD4<Float>(0.7, 0.8, 0.9, 1.0)
        }

        XCTAssertEqual(original.features.buildingFillColor, SIMD4<Float>(0.94902, 0.92549, 0.890196, 1.0))
        XCTAssertEqual(updated.features.buildingFillColor, SIMD4<Float>(0.7, 0.8, 0.9, 1.0))
    }

    func testCacheFingerprintChangesWhenPreparedStyleTokensChange() {
        let original = MapboxDefaultMapStyleConfiguration.mapboxDefault
        let updated = original.labels { labels in
            labels.district.strokeWidthPx = 1.5
        }

        XCTAssertNotEqual(original.cacheFingerprint, updated.cacheFingerprint)
    }

    func testCacheFingerprintCanonicalizesSignedZeroFloatValues() {
        let positiveZero = MapboxDefaultMapStyleConfiguration.mapboxDefault.labels { labels in
            labels.continent.strokeWidthPx = 0.0
        }
        let negativeZero = MapboxDefaultMapStyleConfiguration.mapboxDefault.labels { labels in
            labels.continent.strokeWidthPx = -0.0
        }

        XCTAssertEqual(positiveZero, negativeZero)
        XCTAssertEqual(positiveZero.cacheFingerprint, negativeZero.cacheFingerprint)
    }

    func testMapboxDefaultMapStylePreparedRevisionChangesWhenStyleTokensChange() {
        let defaultSettings = ImmersiveMapSettings.default.style
        let defaultConfiguration = MapboxDefaultMapStyleConfiguration.mapboxDefault
        let customConfiguration = MapboxDefaultMapStyleConfiguration.mapboxDefault.labels { labels in
            labels.district.strokeWidthPx = 1.0
        }

        let defaultRevision = MapboxDefaultMapStyle(configuration: defaultConfiguration,
                                                   settings: defaultSettings).preparedTileStyleRevision
        let customRevision = MapboxDefaultMapStyle(configuration: customConfiguration,
                                                  settings: defaultSettings).preparedTileStyleRevision

        XCTAssertEqual(defaultRevision,
                       defaultSettings.preparedTileStyleRevision &+ defaultConfiguration.cacheFingerprint)
        XCTAssertEqual(customRevision,
                       defaultSettings.preparedTileStyleRevision &+ customConfiguration.cacheFingerprint)
        XCTAssertNotEqual(defaultRevision, customRevision)
    }

    func testLabelFontWeightRawValuesAreStable() {
        XCTAssertEqual(LabelFontWeight.bold.rawValue, 0)
        XCTAssertEqual(LabelFontWeight.thin.rawValue, 1)
    }
}

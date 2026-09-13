// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// The runtime context is derived entirely from the configured map style: the
/// live style object, the label profile, the base colors. The tile source
/// contributes nothing; it is only a URL the loader fetches bytes from.
final class MapStyleRuntimeTests: XCTestCase {
    func testRuntimeContextMaterializesStyleAndLabelProfileOutsideRenderer() {
        let settings = ImmersiveMapSettings.default
            .mapStyle(RuntimeContextTestMapStyle())

        let context = MapStyleRuntime(settings: settings)

        XCTAssertEqual(context.style.cacheFingerprint, 42)
        XCTAssertEqual(context.labelProfile.styleID, "runtime-context-style")
        XCTAssertEqual(context.mapBaseColors.getTileBgColor(), SIMD4<Float>(0.1, 0.2, 0.3, 1.0))
    }

    func testStyleWithoutRuntimeConformanceGetsTheGenericLabelProfile() {
        let settings = ImmersiveMapSettings.default
            .mapStyle(PlainTestMapStyle())

        let context = MapStyleRuntime(settings: settings)

        XCTAssertEqual(context.labelProfile.styleID, AnyImmersiveMapMapStyle.genericStyleID)
    }
}

private struct PlainTestMapStyle: ImmersiveMapMapStyle {
    var configurationFingerprint: UInt64 {
        7
    }

    var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        BasicVectorTileStyle(cacheFingerprint: 7)
    }
}

private struct RuntimeContextTestMapStyle: ImmersiveMapMapStyle {
    var configurationFingerprint: UInt64 {
        42
    }

    var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        RuntimeContextTestStyle()
    }
}

extension RuntimeContextTestMapStyle: ImmersiveMapMapStyleRuntime {
    func makeLabelProfile(settings: ImmersiveMapSettings) -> any LabelStyleProfile {
        RuntimeContextTestLabelStyleProfile(styleID: "runtime-context-style")
    }
}

private struct RuntimeContextTestStyle: ImmersiveMapVectorTileStyle {
    var cacheFingerprint: UInt32 {
        42
    }

    var baseColors: ImmersiveMapSettings.StyleSettings.BaseColors? {
        ImmersiveMapSettings.StyleSettings.BaseColors(
            tileBackground: SIMD4<Float>(0.1, 0.2, 0.3, 1.0),
            globeBackground: SIMD4<Double>(0.0, 0.0, 0.0, 1.0),
            water: SIMD4<Float>(0.0, 0.0, 1.0, 1.0),
            landCover: SIMD4<Float>(0.0, 1.0, 0.0, 1.0)
        )
    }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> FeatureStyle {
        .polygon(key: 1, color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0))
    }

    func backgroundStyle(tileZoom: Int) -> FeatureStyle {
        .polygon(key: 1, color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0))
    }
}

private struct RuntimeContextTestLabelStyleProfile: LabelStyleProfile {
    let styleID: String

    var languagePreferences: VectorTileLabelLanguagePreferences {
        .from(settingsLanguage: .english, fallbackPolicy: .international)
    }

    func sortKey(properties: [String: MvtValue]) -> Int {
        0
    }

    func collisionRank(layerName: String, sortKey: Int) -> Int {
        sortKey
    }

    func includesBasePointLabel(layerName: String,
                                properties: [String: MvtValue],
                                tileZoom: Int,
                                sortKey: Int) -> Bool {
        false
    }

    func identity(feature: VectorTileLabelFeature, text: String, kind: String) -> VectorTileLabelIdentity {
        .styleFeature(styleID: styleID,
                         layerName: feature.layerName,
                         featureID: feature.featureID ?? 0)
    }

    func normalizedKind(layerName: String, properties: [String: MvtValue]) -> String {
        layerName
    }

    func isHouseNumberLayer(_ layerName: String) -> Bool {
        false
    }
}

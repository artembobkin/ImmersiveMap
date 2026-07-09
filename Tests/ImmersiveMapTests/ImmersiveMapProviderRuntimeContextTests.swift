// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapProviderRuntimeContextTests: XCTestCase {
    func testRuntimeContextMaterializesProviderStyleAndLabelProfileOutsideRenderer() {
        let provider = RuntimeContextTestTileProvider(id: "runtime-context-provider")
        let settings = ImmersiveMapSettings.default
            .tileProvider(provider)
            .mapStyle(RuntimeContextTestMapStyle())

        let context = ImmersiveMapProviderRuntimeContext(settings: settings)

        XCTAssertEqual(context.mapStyle.preparedTileStyleRevision, 42)
        XCTAssertEqual(context.labelProviderProfile.providerID, "runtime-context-provider")
        XCTAssertEqual(context.mapBaseColors.getTileBgColor(), SIMD4<Float>(0.1, 0.2, 0.3, 1.0))
    }
}

private struct RuntimeContextTestTileProvider: ImmersiveMapTileProvider {
    let id: String

    var cacheNamespace: String {
        id
    }

    var configurationFingerprint: UInt64 {
        1
    }

    var tileSource: ImmersiveMapTileSource {
        .url(URL(string: "https://example.com/api/v1/map/tiles")!)
    }

    var maximumTileZoomLevel: Int? {
        nil
    }
}

extension RuntimeContextTestTileProvider: ImmersiveMapTileProviderRuntime {
    func makeLabelProviderProfile(settings: ImmersiveMapSettings) -> any VectorTileLabelProviderProfile {
        RuntimeContextTestLabelProviderProfile(providerID: id)
    }
}

private struct RuntimeContextTestMapStyle: ImmersiveMapMapStyle {
    var configurationFingerprint: UInt64 {
        42
    }

    var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        BasicVectorTileStyle(cacheFingerprint: 42)
    }
}

extension RuntimeContextTestMapStyle: ImmersiveMapMapStyleRuntime {
    func makeRuntimeMapStyle(providerID: String,
                             settings: ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle {
        RuntimeContextTestStyle()
    }
}

private final class RuntimeContextTestStyle: ImmersiveMapStyle {
    var preparedTileStyleRevision: UInt32 {
        42
    }

    func getMapBaseColors() -> ImmersiveMapBaseColors {
        ImmersiveMapBaseColors(
            settings: ImmersiveMapSettings.StyleSettings.BaseColors(
                tileBackground: SIMD4<Float>(0.1, 0.2, 0.3, 1.0),
                globeBackground: SIMD4<Double>(0.0, 0.0, 0.0, 1.0),
                water: SIMD4<Float>(0.0, 0.0, 1.0, 1.0),
                landCover: SIMD4<Float>(0.0, 1.0, 0.0, 1.0)
            )
        )
    }

    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        FeatureStyle(
            key: 1,
            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 1)
        )
    }
}

private struct RuntimeContextTestLabelProviderProfile: VectorTileLabelProviderProfile {
    let providerID: String

    var languagePreferences: VectorTileLabelLanguagePreferences {
        .from(settingsLanguage: .english, fallbackPolicy: .international)
    }

    func sortKey(properties: [String: VectorTile_Tile.Value]) -> Int {
        0
    }

    func collisionRank(layerName: String, sortKey: Int) -> Int {
        sortKey
    }

    func includesBasePointLabel(layerName: String,
                                properties: [String: VectorTile_Tile.Value],
                                tileZoom: Int,
                                sortKey: Int) -> Bool {
        false
    }

    func identity(feature: VectorTileLabelFeature, text: String, kind: String) -> VectorTileLabelIdentity {
        .providerFeature(providerID: providerID,
                         layerName: feature.layerName,
                         featureID: feature.featureID ?? 0)
    }

    func normalizedKind(layerName: String, properties: [String: VectorTile_Tile.Value]) -> String {
        layerName
    }

    func isHouseNumberLayer(_ layerName: String) -> Bool {
        false
    }
}

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
        XCTAssertEqual(context.styleID, "runtime-context-style")
        XCTAssertEqual(context.baseColors.map, SIMD4<Float>(0.1, 0.2, 0.3, 1.0))
    }

    func testStyleWithoutAnIdentityGetsTheGenericOne() {
        let settings = ImmersiveMapSettings.default
            .mapStyle(PlainTestMapStyle())

        let context = MapStyleRuntime(settings: settings)

        XCTAssertEqual(context.styleID, AnyImmersiveMapMapStyle.genericStyleID)
    }
}

private struct PlainTestMapStyle: ImmersiveMapMapStyle {
    var configurationFingerprint: UInt64 {
        7
    }

    var schema: any ImmersiveMapTileSchema {
        ProtomapsBasemapSchema()
    }

    var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        BasicVectorTileStyle(cacheFingerprint: 7)
    }
}

private struct RuntimeContextTestMapStyle: ImmersiveMapMapStyle {
    var configurationFingerprint: UInt64 {
        42
    }

    var schema: any ImmersiveMapTileSchema {
        ProtomapsBasemapSchema()
    }

    var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        RuntimeContextTestStyle()
    }
}

private struct RuntimeContextTestStyle: ImmersiveMapVectorTileStyle {
    var cacheFingerprint: UInt32 {
        42
    }

    var styleID: String {
        "runtime-context-style"
    }

    var baseColors: ImmersiveMapBaseColors {
        ImmersiveMapBaseColors(map: SIMD4<Float>(0.1, 0.2, 0.3, 1.0),
                               northCap: SIMD4<Float>(0.0, 0.0, 1.0, 1.0),
                               southCap: SIMD4<Float>(1.0, 1.0, 1.0, 1.0))
    }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> FeatureStyle {
        .polygon(key: 1, color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0))
    }

    func backgroundStyle(tileZoom: Int) -> FeatureStyle {
        .polygon(key: 1, color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0))
    }
}


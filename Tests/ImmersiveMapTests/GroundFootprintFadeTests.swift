// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The footprint fade of the flat ground fills: the CPU mirror of the
/// shader's band, the style layout it rides on, and the far tones the
/// default style assigns.
final class GroundFootprintFadeTests: XCTestCase {
    func testAmountIsASmoothstepOverTheBand() {
        XCTAssertEqual(GroundFootprintFade.amount(unitsPerPixel: 0), 0)
        XCTAssertEqual(GroundFootprintFade.amount(unitsPerPixel: GroundFootprintFade.startUnits), 0)
        XCTAssertEqual(GroundFootprintFade.amount(unitsPerPixel: GroundFootprintFade.endUnits), 1)
        XCTAssertEqual(GroundFootprintFade.amount(unitsPerPixel: 10_000), 1)
        let middle = (GroundFootprintFade.startUnits + GroundFootprintFade.endUnits) / 2
        XCTAssertEqual(GroundFootprintFade.amount(unitsPerPixel: middle), 0.5, accuracy: 1e-6)
        // A tile at its native scale (8 units per point, 4 per pixel on a
        // 2x screen) never fades: the band starts well above it.
        XCTAssertEqual(GroundFootprintFade.amount(unitsPerPixel: 4), 0)
    }

    /// The style buffer is one layout shared by the ground, the bridge
    /// overlay and the buildings: four colours, mirrored by the `Style`
    /// structs of both tile shaders.
    func testStyleLayoutCarriesTheFarColourPair() throws {
        XCTAssertEqual(MemoryLayout<TilePolygonStyle>.stride, 64)
        let plain = TilePolygonStyle(color: SIMD4<Float>(1, 0, 0, 1))
        XCTAssertEqual(plain.farColor, SIMD4<Float>(0, 0, 0, 0), "No far colour: the fade strength is zero")
        XCTAssertEqual(plain.farStreetColor, plain.farColor)
        for path in ["Render/Tiles/Shaders/TileShading.h", "Render/Tiles/Shaders/TileExtruded.metal"] {
            let source = try shaderSource(path)
            let styleStruct = try XCTUnwrap(source.range(of: "struct Style {"))
            let body = source[styleStruct.upperBound...]
            let end = try XCTUnwrap(body.range(of: "};"))
            let fields = body[..<end.lowerBound]
            XCTAssertEqual(fields.components(separatedBy: "float4 ").count - 1, 4,
                           "\(path): the Style struct must carry exactly four float4 fields")
            XCTAssertTrue(fields.contains("float4 farColor;") && fields.contains("float4 farStreetColor;"), path)
        }
        let shading = try shaderSource("Render/Tiles/Shaders/TileShading.h")
        XCTAssertTrue(shading.contains("smoothstep(fade.startUnits, fade.endUnits, unitsPerPixel)"),
                      "The shader fades over the same band as the CPU mirror")
        let tile = try shaderSource("Render/Tiles/Shaders/Tile.metal")
        XCTAssertTrue(tile.contains("constant FootprintFadeUniform& footprintFade [[buffer(10), function_constant(kTileFillFields)]]"))
    }

    /// The default style fades the land classes to the vegetation base and
    /// leaves water at full contrast at every distance.
    func testDefaultStyleAssignsFarTonesToLandCoverOnly() {
        let config = ImmersiveMapSettings.default
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        func style(layer: String, cls: String, z: Int = 8) -> FeatureStyle {
            runtimeContext.mapStyle.makeStyle(data: DetFeatureStyleData(layerName: layer,
                                                                        properties: ["class": .string(cls)],
                                                                        tile: Tile(x: 0, y: 0, z: z)))
        }
        let crop = style(layer: "globallandcover", cls: "crop")
        let forest = style(layer: "globallandcover", cls: "forest")
        let urban = style(layer: "globallandcover", cls: "urban")
        let water = style(layer: "water", cls: "lake")
        let snow = style(layer: "globallandcover", cls: "snow")
        XCTAssertEqual(crop.farColor?.w, 1, "Crops fade fully")
        XCTAssertEqual(crop.farColor.map { SIMD3($0.x, $0.y, $0.z) }, forest.farColor.map { SIMD3($0.x, $0.y, $0.z) },
                       "Crops and forests converge on the same tone")
        XCTAssertEqual(urban.farColor?.w, 0.75, "Settlements keep a quarter of their distance")
        XCTAssertNil(water.farColor, "Water never fades: a far lake stays a lake")
        XCTAssertNil(snow.farColor, "Ice caps are real edges")
        let wood = style(layer: "landcover", cls: "wood", z: 12)
        let streetGrass = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault.layers.grass
        XCTAssertEqual(wood.farStreetColor.map { SIMD3($0.x, $0.y, $0.z) },
                       SIMD3(streetGrass.x, streetGrass.y, streetGrass.z),
                       "OSM woods converge on the street grass tone")
    }

    private func shaderSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("ImmersiveMap/\(relativePath)"), encoding: .utf8)
    }
}

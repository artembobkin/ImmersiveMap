// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The placeIn clip of a retained substitute (a parent drawn in a missing
/// child's slot) is applied by the rasterizer through vertex-stage clip
/// distances, never by a fragment discard. A discard in either tile shader
/// would turn every ground and building draw into punch-through geometry
/// that the GPU must shade before it knows the coverage, which defeats
/// hidden surface removal for the whole world pass; the clip distances give
/// the same slot edge, cut geometrically, with no fragment ever born outside
/// it. Reads the shader sources off the checkout, so it cannot run on a
/// device.
final class TileClipDistanceContractTests: XCTestCase {
    func testGroundShaderClipsWithClipDistancesAndNeverDiscards() throws {
        let source = try shaderSource("Render/Tiles/Shaders/Tile.metal")
        XCTAssertNil(source.range(of: "discard_fragment"),
                     "The ground shader must not discard: it blocks hidden surface removal for every ground draw")
        XCTAssertTrue(source.contains("float clipDistance [[clip_distance]] [4];"),
                      "The placeIn slot is cut by four clip distances in the vertex stage")
        XCTAssertTrue(source.contains("constant float4& localClipBounds [[buffer(7)]]"),
                      "The bounds arrive in the vertex stage at buffer 7, where the drawers bind them")
        XCTAssertNil(source.range(of: "localClipBounds [[buffer(1)]]"),
                     "The fragment stage no longer takes the bounds")
    }

    func testBuildingShadersClipWithClipDistancesAndNeverDiscard() throws {
        let source = try shaderSource("Render/Tiles/Shaders/TileExtruded.metal")
        XCTAssertNil(source.range(of: "discard_fragment"),
                     "The building shaders must not discard, on the main path or the shadow-caster path")
        XCTAssertEqual(source.components(separatedBy: "float clipDistance [[clip_distance]] [4];").count - 1, 2,
                       "Both the main and the shadow-caster vertex outputs carry the clip distances")
        XCTAssertEqual(source.components(separatedBy: "constant float4& localClipBounds [[buffer(4)]]").count - 1, 2,
                       "Both vertex stages take the bounds at buffer 4, where the drawer binds them")
        XCTAssertNil(source.range(of: "tileExtrudedShadowFragmentShader"),
                     "The shadow-caster pass is depth-only: no fragment function replicates the clip")
    }

    /// The flat ground reads its shadow from the per-pixel mask instead of
    /// sampling the cascades in every blended layer; the atlas bake keeps
    /// the direct path behind the function constant.
    func testGroundShaderReadsTheGroundShadowMaskBehindAFunctionConstant() throws {
        let source = try shaderSource("Render/Tiles/Shaders/Tile.metal")
        XCTAssertTrue(source.contains("constant bool kGroundShadowMaskEnabled [[function_constant(0)]];"))
        XCTAssertTrue(source.contains("texture2d<half> groundShadowMask [[texture(1), function_constant(kGroundShadowMaskEnabled)]]"))
        XCTAssertTrue(source.contains("depth2d_array<float> shadowMap [[texture(0), function_constant(kSamplesShadowCascades)]]"))
        XCTAssertTrue(source.contains("groundShadowMask.sample(maskSampler, in.position.xy * kGroundShadowMaskScale).r"))
        XCTAssertTrue(source.contains("constant float kGroundShadowMaskScale = \(GroundShadowMaskPipeline.resolutionScale);"),
                      "The shader's mask scale must mirror GroundShadowMaskPipeline.resolutionScale")
        let mask = try shaderSource("Render/Tiles/Shaders/GroundShadowMask.metal")
        XCTAssertTrue(mask.contains("fragment half groundShadowMaskFragmentShader("))
        XCTAssertTrue(mask.contains("sampleShadowFactor(shadow, shadowMap, worldPosition, float3(0.0))"),
                      "The mask pass samples the cascades exactly the way the ground plane did, with no normal")
    }

    /// The sphere tile shader: the same clip, one more distance for the
    /// horizon, no textures and no discard, lit through the shared globe
    /// surface shading.
    func testSphereShaderClipsWithSlotDistancesAndNeverDiscards() throws {
        let source = try shaderSource("Render/Tiles/Shaders/TileSphere.metal")
        XCTAssertNil(source.range(of: "discard_fragment"))
        // The resting sphere carries the four slot clips; the morph adds the
        // unroll's cut as a fifth.
        XCTAssertTrue(source.contains("float clipDistance [[clip_distance]] [4];"))
        XCTAssertTrue(source.contains("float clipDistance [[clip_distance]] [5];"))
        XCTAssertTrue(source.contains("kGlobeUnrollCutCosine"))
        XCTAssertTrue(source.contains("constant float4& localClipBounds [[buffer(7)]]"))
        XCTAssertTrue(source.contains("constant GlobeSurfaceTile& surfaceTile [[buffer(9)]]"))
        XCTAssertNil(source.range(of: "shadowMap"))
        XCTAssertNil(source.range(of: "groundShadowMask"))
        XCTAssertNil(source.range(of: "OcclusionClearance"),
                     "The sphere needs no occlusion clip: back-face culling removes the far side; the morph clips only the unroll's cut")
        XCTAssertTrue(source.contains("globeWorldUVLatLon("))
    }

    /// A tile's vertices unwrap their flat morph target around the tile's
    /// centre, on the sphere pipeline, the label kernel and the placeholder
    /// grid alike, so no triangle spans the map at the seam of the wrap.
    func testTileGeometryUnwrapsAroundTheTileCentre() throws {
        let projection = try shaderSource("Render/Shaders/Globe/GlobeTileProjection.h")
        XCTAssertTrue(projection.contains("static inline float globeTileReferenceWorldX(int3 tile)"))
        XCTAssertGreaterThanOrEqual(projection.components(separatedBy: "globeTileReferenceWorldX(tile)").count - 1, 1,
                       "The tile projection passes the tile's centre")
        let transition = try shaderSource("Render/Shaders/Globe/GlobeTransitionProjection.h")
        XCTAssertTrue(transition.contains("float referenceNormalizedWorldX,"))
        XCTAssertTrue(transition.contains("return reference + wrap(value - reference, mapSize);"))
        let sphere = try shaderSource("Render/Tiles/Shaders/TileSphere.metal")
        XCTAssertTrue(sphere.contains("surfaceTile.referenceWorldX)"))
    }



    private func shaderSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("ImmersiveMap/\(relativePath)"), encoding: .utf8)
    }
}

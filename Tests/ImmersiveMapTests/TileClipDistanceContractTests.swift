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
        // The flat tiles carry NO slot clip distances any more: a retained
        // substitute draws at full extent and the tile-priority stencil
        // rejects it wherever a finer tile painted, exactly like the
        // sphere. Only the buildings keep their slot clips (TileExtruded).
        // The one clip distance here is the road distance cut, the outer
        // radius of the road fade ring about the look-at point
        // (RoadDistanceLOD), no slot's edge.
        XCTAssertNil(source.range(of: "localClipBounds"))
        XCTAssertNil(source.range(of: "[[clip_distance]] [4]"))
        XCTAssertTrue(source.contains("float clipDistance [[clip_distance]] [1];"))
        XCTAssertTrue(source.contains("constant RoadDistanceFadeUniform& roadFade [[buffer(9)]]"))
        XCTAssertTrue(source.contains("float centerDistance = length(worldPosition.xy - roadFade.centerWorld);"),
                      "The fade measures on the ground plane from the look-at point, not from the eye")
        XCTAssertTrue(source.contains("out.clipDistance[0] = roadFade.enabled > 0.5 ? roadFade.endWorld - centerDistance : 1.0;"))
        XCTAssertTrue(source.contains("color.a *= half(in.distanceFade);"),
                      "The lines fragment applies the fade the vertex stage resolved")
        XCTAssertEqual(MemoryLayout<TileRoadDistanceFadeUniform>.stride, 32,
                       "A float2 and six floats, the shader's RoadDistanceFadeUniform")
        XCTAssertEqual(MemoryLayout<TileRoadDistanceFadeUniform>.offset(of: \.startWorld), 8)
        XCTAssertEqual(MemoryLayout<TileRoadDistanceFadeUniform>.offset(of: \.enabled), 16)
        // The flat rank-depth step is one value with the sphere's, both
        // mirrored by GlobeSurfaceDepthRank.
        XCTAssertTrue(source.contains("constant float kFlatTileLayerDepthStep = 4e-7;"))
        XCTAssertTrue(source.contains("constant float& depthBandOffset [[buffer(7)]]"))
    }

    func testBuildingShadersClipWithSlotDistancesOnBothPaths() throws {
        let source = try shaderSource("Render/Tiles/Shaders/TileExtruded.metal")
        XCTAssertNil(source.range(of: "discard_fragment"),
                     "The building shaders must not discard, on the main path or the shadow-caster path")
        // The building coverage is a partition of the ground: a parent
        // filling a slot its finer tiles do not cover is cut to the slot by
        // the vertex-stage clip, in the world pass and in the shadow pass
        // alike (the shadow pass has no stencil, the world pass tests none
        // for buildings), so both vertex stages carry the four distances
        // and take the bounds at buffer 4.
        XCTAssertEqual(source.components(separatedBy: "float clipDistance [[clip_distance]] [4];").count - 1, 2,
                       "Both vertex outputs carry the slot clip distances")
        XCTAssertEqual(source.components(separatedBy: "constant float4& localClipBounds [[buffer(4)]]").count - 1, 2,
                       "Both vertex stages take the bounds at buffer 4")
        let mainVertex = source.components(separatedBy: "vertex VertexOut tileExtrudedVertexShader")[1]
            .components(separatedBy: "fragment")[0]
        XCTAssertNotNil(mainVertex.range(of: "writeLocalClipDistances(out.clipDistance"),
                        "The main vertex stage writes the slot clip distances")
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
        XCTAssertTrue(source.contains("depth2d<float> shadowMap [[texture(0), function_constant(kSamplesShadowCascades)]]"))
        XCTAssertTrue(source.contains("groundShadowMask.sample(maskSampler, in.position.xy * kGroundShadowMaskScale).r"))
        XCTAssertTrue(source.contains("constant float kGroundShadowMaskScale = \(GroundShadowMaskPipeline.resolutionScale);"),
                      "The shader's mask scale must mirror GroundShadowMaskPipeline.resolutionScale")
        let mask = try shaderSource("Render/Tiles/Shaders/GroundShadowMask.metal")
        XCTAssertTrue(mask.contains("fragment half groundShadowMaskFragmentShader("))
        // The mask takes no screen derivatives, which is what licenses its
        // early exits: a pixel above the horizon or beyond the fade returns
        // lit without touching the map.
        XCTAssertNil(mask.range(of: "sampleShadowFactor("),
                     "The mask uses the specialized ground-plane path, not the generic receiver sampling")
        XCTAssertNil(mask.range(of: "dfdx"), "No screen derivatives: control flow may diverge")
        XCTAssertTrue(mask.contains("if (distanceToCenter >= shadow.fadeEndDistance) {"),
                      "Pixels beyond the shadow fade exit before sampling")
        XCTAssertTrue(mask.contains("length(worldPosition.xy - shadow.fadeCenter)"),
                      "The fade is radial from the window's centre, not from the eye")
        XCTAssertTrue(mask.contains("shadowWindowVisibility(shadow.cascade, shadowMap, uvz)"),
                      "The mask reads the shared sampler, the same one every receiver reads")
        // One kernel for the whole frame. A tent on the ground next to a
        // single tap on a wall reads as two different shadow systems in one
        // picture, which is worse than either on its own.
        let uniforms = try shaderSource("Render/Shaders/Shared/RenderUniforms.h")
        XCTAssertEqual(uniforms.components(separatedBy: "sample_compare(").count - 1, 4,
                       "The tent is four taps, and it is the only place that samples the shadow map")
        XCTAssertNil(mask.range(of: "sample_compare("),
                     "The mask must not grow a kernel of its own")
        let extruded = try shaderSource("Render/Tiles/Shaders/TileExtruded.metal")
        XCTAssertNil(extruded.range(of: "sample_compare("),
                     "Buildings must not grow a kernel of their own")
        let sceneModel = try shaderSource("Render/SceneModels/Shaders/SceneModel.metal")
        XCTAssertNil(sceneModel.range(of: "sample_compare("),
                     "Scene models must not grow a kernel of their own")
        XCTAssertNil(mask.range(of: "for ("),
                     "One window: nothing to loop over, and no cascade cross-fade")
    }

    /// The sphere tile shader: the same clip, one more distance for the
    /// horizon, no textures and no discard, lit through the shared globe
    /// surface shading.
    func testSphereShaderClipsWithSlotDistancesAndNeverDiscards() throws {
        let source = try shaderSource("Render/Tiles/Shaders/TileSphere.metal")
        XCTAssertNil(source.range(of: "discard_fragment"))
        // The resting sphere carries the four slot clips; the morph adds the
        // unroll's cut as a fifth.
        // The sphere carries NO slot clip distances at all: unique sources
        // draw at full extent, on the resting sphere and during the morph
        // alike, and the source-zoom depth band rejects a coarse
        // substitute's overflow (kTileSphereLayerDepthStep). The morph
        // keeps exactly one clip: the unroll's cut.
        XCTAssertNil(source.range(of: "[[clip_distance]] [4]"))
        XCTAssertNil(source.range(of: "[[clip_distance]] [5]"))
        XCTAssertTrue(source.contains("float clipDistance [[clip_distance]] [1];"))
        XCTAssertTrue(source.contains("globeUnrollCutClearance("))
        XCTAssertNil(source.range(of: "localClipBounds"))
        // Which tile owns a pixel is the stencil's job now, not depth's.
        XCTAssertNil(source.range(of: "depthBias"))
        // The depth constants are a binding contract with the CPU mirror.
        XCTAssertTrue(source.contains("constant float kTileSphereLayerDepthStep = 4e-7;"))
        XCTAssertEqual(GlobeSurfaceDepthRank.layerDepthStep, 4e-7)
        XCTAssertEqual(GlobeSurfaceDepthRank.classDepthBand, 257 * 4e-7)
        XCTAssertTrue(source.contains("constant GlobeSurfaceTile& surfaceTile [[buffer(9)]]"))
        XCTAssertNil(source.range(of: "shadowMap"))
        XCTAssertNil(source.range(of: "groundShadowMask"))
        XCTAssertNil(source.range(of: "OcclusionClearance"),
                     "The sphere needs no occlusion clip: back-face culling removes the far side; the morph clips only the unroll's cut")
        XCTAssertTrue(source.contains("globeWorldUVUnitDirection("))
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

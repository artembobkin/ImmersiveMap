// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import QuartzCore
import XCTest

/// Regression for a startup crash: `tileFragmentShader` statically references
/// the shadow map, and the atlas rasterization path (`TileAtlasTexture.draw`)
/// must bind the fallback texture + disabled uniform, because a missing binding
/// aborts the process under Metal API validation on the first drawn tile.
/// This encodes a real atlas draw with non-empty ground geometry end-to-end.
final class TileAtlasShadowBindingTests: XCTestCase {
    func testAtlasDrawWithGroundGeometryCompletesWithShadowFallback() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard let library = try? device.makeDefaultLibrary(bundle: .module) else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Command queue is unavailable")
        }

        let tilePipeline = TilePipeline(metalDevice: device,
                                        pixelFormat: .bgra8Unorm,
                                        library: library,
                                        sampleCount: 1)

        let fallbackDescriptor = MTLTextureDescriptor()
        fallbackDescriptor.textureType = .type2DArray
        fallbackDescriptor.pixelFormat = ShadowCascadeAtlas.depthPixelFormat
        fallbackDescriptor.width = 1
        fallbackDescriptor.height = 1
        fallbackDescriptor.arrayLength = ShadowCascadeAtlas.cascadeCount
        fallbackDescriptor.usage = [.renderTarget, .shaderRead]
        fallbackDescriptor.storageMode = .private
        let fallbackTexture = try XCTUnwrap(device.makeTexture(descriptor: fallbackDescriptor))

        let providerRuntime = ImmersiveMapProviderRuntimeContext(settings: .default)
        let atlas = TileAtlasTexture(metalDevice: device,
                                     tilePipeline: tilePipeline,
                                     shadowFallbackTexture: fallbackTexture,
                                     mapBaseColors: providerRuntime.mapBaseColors)

        let tile = Tile(x: 0, y: 0, z: 0)
        let allocation = TileAtlasAllocation(
            candidate: TileAtlasCandidate(placementIndex: 0,
                                          placeTile: PlaceTile(metalTile: MetalTile(tile: tile,
                                                                                    tileBuffers: try makeTriangleTileBuffers(device: device)),
                                                               placeIn: VisibleTile(tile: tile),
                                                               lodKind: .exact),
                                          screenDemandPx: 256,
                                          distanceToCamera: 0,
                                          desiredDepth: .depth0),
            pageIndex: 0,
            placedPosition: PlacedPos(depth: 0, x: 0, y: 0),
            atlasDepth: .depth0,
            cellSizePx: 4096)

        let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
        XCTAssertTrue(atlas.beginPageEncoding(commandBuffer: commandBuffer, pageIndex: 0))
        atlas.selectTilePipeline()
        atlas.setOverviewFadeAlphas(overviewAlpha: 1, roadAlpha: 1, landuseAlpha: 1)
        XCTAssertTrue(atlas.draw(allocation: allocation),
                      "The atlas draw with non-empty ground geometry must encode")
        atlas.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error, "The atlas draw must complete without GPU errors")
    }

    /// Minimal tile with one real ground triangle so `draw` reaches
    /// `drawIndexedPrimitives` (an empty layer returns before binding checks).
    private func makeTriangleTileBuffers(device: MTLDevice) throws -> TileBuffers {
        let vertices: [TilePipeline.VertexIn] = [
            TilePipeline.VertexIn(position: SIMD2<Int16>(0, 0), styleIndex: 0),
            TilePipeline.VertexIn(position: SIMD2<Int16>(4096, 0), styleIndex: 0),
            TilePipeline.VertexIn(position: SIMD2<Int16>(0, 4096), styleIndex: 0)
        ]
        let indices: [UInt32] = [0, 1, 2]
        let styles = [TilePolygonStyle(color: SIMD4<Float>(1, 0, 0, 1))]
        let overviewMask: [Float] = [0]

        let totalLength = TileBufferArena.alignedSize(of: vertices)
            + TileBufferArena.alignedSize(of: indices)
            + TileBufferArena.alignedSize(of: styles)
            + TileBufferArena.alignedSize(of: overviewMask)
        let arena = try XCTUnwrap(TileBufferArena(metalDevice: device, length: totalLength))

        let ground = TileBuffers.GeometryLayer(vertices: arena.append(vertices),
                                               indices: arena.append(indices),
                                               styles: arena.append(styles),
                                               overviewStyleMask: arena.append(overviewMask),
                                               indexType: .uint32)
        let emptyLayer = TileBuffersFixtures.emptyGeometryLayer()
        let phases = RoadGeometryPhases(shadow: emptyLayer,
                                        casing: emptyLayer,
                                        fill: emptyLayer,
                                        detail: emptyLayer,
                                        overlay: emptyLayer)
        return TileBuffers(backingBuffer: arena.backingBuffer,
                           ground: ground,
                           roads: RoadStructureBuckets(tunnel: phases,
                                                       ground: phases,
                                                       bridge: phases),
                           bridgeOverlay: emptyLayer,
                           extruded: TileBuffers.Extruded(vertices: nil,
                                                          indices: nil,
                                                          styles: nil,
                                                          indexType: .uint32),
                           textLabels: TileBuffers.TextLabels(full: TileBuffersFixtures.emptyTextLabelSet(),
                                                               reduced: TileBuffersFixtures.emptyTextLabelSet(),
                                                               minimal: TileBuffersFixtures.emptyTextLabelSet()),
                           roadLabels: TileBuffersFixtures.emptyRoadLabels())
    }
}

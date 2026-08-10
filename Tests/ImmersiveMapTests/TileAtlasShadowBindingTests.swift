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

        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShadowCascadeAtlas.depthPixelFormat,
                                                                          width: 1,
                                                                          height: 1,
                                                                          mipmapped: false)
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

        let verticesBuffer = try XCTUnwrap(device.makeBuffer(bytes: vertices,
                                                             length: vertices.count * MemoryLayout<TilePipeline.VertexIn>.stride))
        let indicesBuffer = try XCTUnwrap(device.makeBuffer(bytes: indices,
                                                            length: indices.count * MemoryLayout<UInt32>.stride))
        let stylesBuffer = try XCTUnwrap(device.makeBuffer(bytes: styles,
                                                           length: styles.count * MemoryLayout<TilePolygonStyle>.stride))
        let maskBuffer = try XCTUnwrap(device.makeBuffer(bytes: overviewMask,
                                                         length: overviewMask.count * MemoryLayout<Float>.stride))

        let ground = TileBuffers.GeometryLayer(verticesBuffer: verticesBuffer,
                                               indicesBuffer: indicesBuffer,
                                               stylesBuffer: stylesBuffer,
                                               overviewStyleMaskBuffer: maskBuffer,
                                               indicesCount: indices.count,
                                               verticesCount: vertices.count,
                                               indexType: .uint32)
        let emptyLayer = TileBuffers.GeometryLayer(verticesBuffer: verticesBuffer,
                                                   indicesBuffer: indicesBuffer,
                                                   stylesBuffer: stylesBuffer,
                                                   overviewStyleMaskBuffer: maskBuffer,
                                                   indicesCount: 0,
                                                   verticesCount: 0,
                                                   indexType: .uint32)
        let extruded = TileBuffers.Extruded(verticesBuffer: verticesBuffer,
                                            indicesBuffer: indicesBuffer,
                                            stylesBuffer: stylesBuffer,
                                            indicesCount: 0,
                                            verticesCount: 0,
                                            indexType: .uint32)
        let phases = RoadGeometryPhases(shadow: emptyLayer,
                                        casing: emptyLayer,
                                        fill: emptyLayer,
                                        detail: emptyLayer,
                                        overlay: emptyLayer)
        let roads = RoadStructureBuckets(tunnel: phases,
                                         ground: phases,
                                         bridge: phases)
        let emptyTextLabelSet = TileBuffers.TextLabelSet(placementInputs: [],
                                                         labelsByStyleRuns: [],
                                                         poiIconRuns: [])
        return TileBuffers(ground: ground,
                           roads: roads,
                           bridgeOverlay: emptyLayer,
                           extruded: extruded,
                           textLabels: TileBuffers.TextLabels(full: emptyTextLabelSet,
                                                               reduced: emptyTextLabelSet,
                                                               minimal: emptyTextLabelSet),
                           roadLabels: TileBuffers.RoadLabels(pathInputs: [],
                                                              pathRanges: [],
                                                              pathLabels: [],
                                                              labelStyle: nil,
                                                              localGlyphVerticesBuffer: nil,
                                                              localGlyphVertexCount: 0,
                                                              glyphBounds: [],
                                                              glyphBoundRanges: [],
                                                              sizes: [],
                                                              anchorRanges: [],
                                                              anchors: []))
    }
}

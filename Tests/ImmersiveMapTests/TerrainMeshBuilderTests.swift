// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class TerrainMeshBuilderTests: XCTestCase {
    func testFlatMeshUsesResolutionSquaredVerticesGridIndicesAndTileLocalPositions() {
        let grid = TerrainHeightGrid(width: 2, height: 2, heightsMeters: [0, 10, 20, 30])

        let mesh = TerrainMeshBuilder.buildFlatMesh(tile: Tile(x: 0, y: 0, z: 0),
                                                    heightGrid: grid,
                                                    resolution: 3,
                                                    exaggeration: 2.0,
                                                    heightScale: 0.01)

        XCTAssertEqual(mesh.vertices.count, 9)
        XCTAssertEqual(mesh.indices.count, 24)
        XCTAssertEqual(mesh.vertices.first?.position, SIMD3<Float>(0, 4096, 0))
        XCTAssertEqual(mesh.vertices.last?.position.x, 4096)
        XCTAssertEqual(mesh.vertices.last?.position.y, 0)
        XCTAssertEqual(mesh.vertices.last?.position.z ?? 0, 0.6, accuracy: 0.000001)
    }

    func testMeshBuilderClampsResolutionToAtLeastTwo() {
        let grid = TerrainHeightGrid(width: 1, height: 1, heightsMeters: [100])

        let mesh = TerrainMeshBuilder.buildFlatMesh(tile: Tile(x: 0, y: 0, z: 0),
                                                    heightGrid: grid,
                                                    resolution: 1,
                                                    exaggeration: 1.0,
                                                    heightScale: 0.01)

        XCTAssertEqual(mesh.vertices.count, 4)
        XCTAssertEqual(mesh.indices.count, 6)
    }

    func testGlobeMeshMovesVerticesOutwardByHeight() {
        let grid = TerrainHeightGrid(width: 1, height: 1, heightsMeters: [100])

        let mesh = TerrainMeshBuilder.buildGlobeMesh(tile: Tile(x: 0, y: 0, z: 0),
                                                     heightGrid: grid,
                                                     resolution: 2,
                                                     globeRadius: 10,
                                                     exaggeration: 1,
                                                     heightScale: 0.01)

        XCTAssertEqual(mesh.vertices.count, 4)
        XCTAssertTrue(mesh.vertices.allSatisfy { vertex in
            abs(simd_length(vertex.position) - 11) < 0.001
        })
    }

    func testGlobeMeshUsesEstablishedMercatorSphereBasis() {
        let grid = TerrainHeightGrid(width: 1, height: 1, heightsMeters: [0])

        let mesh = TerrainMeshBuilder.buildGlobeMesh(tile: Tile(x: 0, y: 0, z: 0),
                                                     heightGrid: grid,
                                                     resolution: 2,
                                                     globeRadius: 10,
                                                     exaggeration: 1,
                                                     heightScale: 1)

        let expectedPosition = establishedGlobePosition(tile: Tile(x: 0, y: 0, z: 0),
                                                        u: 0,
                                                        v: 0,
                                                        radius: 10)

        XCTAssertEqual(mesh.vertices.first?.position.x ?? 0, expectedPosition.x, accuracy: 0.000001)
        XCTAssertEqual(mesh.vertices.first?.position.y ?? 0, expectedPosition.y, accuracy: 0.000001)
        XCTAssertEqual(mesh.vertices.first?.position.z ?? 0, expectedPosition.z, accuracy: 0.000001)
    }

    func testGlobeMeshKeepsEquatorPrimeMeridianInUnplacedSphereSpace() {
        let grid = TerrainHeightGrid(width: 1, height: 1, heightsMeters: [0])

        let mesh = TerrainMeshBuilder.buildGlobeMesh(tile: Tile(x: 1, y: 1, z: 1),
                                                     heightGrid: grid,
                                                     resolution: 2,
                                                     globeRadius: 10,
                                                     exaggeration: 1,
                                                     heightScale: 1)

        XCTAssertEqual(mesh.vertices.first?.position.x ?? 0, 0, accuracy: 0.000001)
        XCTAssertEqual(mesh.vertices.first?.position.y ?? 0, 0, accuracy: 0.000001)
        XCTAssertEqual(mesh.vertices.first?.position.z ?? 0, 10, accuracy: 0.000001)
    }

    private func establishedGlobePosition(tile: Tile,
                                          u: Double,
                                          v: Double,
                                          radius: Float) -> SIMD3<Float> {
        let tilesCount = Double(1 << tile.z)
        let normalizedX = (Double(tile.x) + u) / tilesCount
        let normalizedY = (Double(tile.y) + v) / tilesCount
        let longitude = ImmersiveMapProjection.longitude(fromNormalizedWorldX: normalizedX)
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: normalizedY)
        let phi = Float(latitude) - (.pi * 0.5)
        let theta = Float(longitude + Double.pi)
        let normal = simd_normalize(SIMD3<Float>(sin(phi) * sin(theta),
                                                 cos(phi),
                                                 sin(phi) * cos(theta)))
        return normal * radius
    }
}

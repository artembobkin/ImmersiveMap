// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

final class StarfieldStarCountTests: XCTestCase {
    func testZeroStarCountProducesEmptyModel() {
        XCTAssertTrue(StarfieldModel.makeStars(config: makeConfig(starCount: 0)).isEmpty)
    }

    func testNegativeStarCountProducesEmptyModel() {
        XCTAssertTrue(StarfieldModel.makeStars(config: makeConfig(starCount: -5)).isEmpty)
    }

    func testSmallStarCountsProduceExactlyRequestedStars() {
        for starCount in 1...24 {
            let stars = StarfieldModel.makeStars(config: makeConfig(starCount: starCount))
            XCTAssertEqual(stars.count, starCount, "starCount \(starCount)")
        }
    }

    func testDefaultStarCountProducesExactlyRequestedStars() {
        let config = ImmersiveMapSettings.default.scene.starfield
        XCTAssertEqual(StarfieldModel.makeStars(config: config).count, config.starCount)
    }

    /// The renderer must not force-unwrap the vertex buffer: `makeBuffer(bytes:length:)`
    /// returns nil for a zero length, which used to crash an empty starfield.
    func testRendererDoesNotForceUnwrapVertexBuffer() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rendererURL = packageRootURL
            .appendingPathComponent("ImmersiveMap/Render/Starfield/StarfieldRenderer.swift")
        let source = try String(contentsOf: rendererURL, encoding: .utf8)

        XCTAssertFalse(source.contains("MemoryLayout<StarVertex>.stride * stars.count)!"))
        XCTAssertTrue(source.contains("if let verticesBuffer, verticesCount > 0 {"))
    }

    private func makeConfig(starCount: Int) -> ImmersiveMapSettings.StarfieldSettings {
        var config = ImmersiveMapSettings.default.scene.starfield
        config.starCount = starCount
        return config
    }
}

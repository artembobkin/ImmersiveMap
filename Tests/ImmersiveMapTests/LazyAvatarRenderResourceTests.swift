// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class LazyAvatarRenderResourceTests: XCTestCase {
    private final class TestResource {}

    func testFactoryRunsOnlyOnFirstValueAccess() {
        var creationCount = 0
        let resource = LazyAvatarRenderResource {
            creationCount += 1
            return TestResource()
        }

        XCTAssertFalse(resource.isInitialized)
        XCTAssertEqual(creationCount, 0)

        let firstValue = resource.value
        let secondValue = resource.value

        XCTAssertTrue(resource.isInitialized)
        XCTAssertEqual(creationCount, 1)
        XCTAssertTrue(firstValue === secondValue)
        XCTAssertTrue(resource.existingValue === firstValue)
    }

    func testReadingExistingValueDoesNotRunFactory() {
        var creationCount = 0
        let resource = LazyAvatarRenderResource {
            creationCount += 1
            return TestResource()
        }

        XCTAssertNil(resource.existingValue)
        XCTAssertFalse(resource.isInitialized)
        XCTAssertEqual(creationCount, 0)
    }

    func testRendererStoresEveryAtlasAsLazyResource() throws {
        let source = try rendererSource()
        let declarations = [
            "private let avatarAtlasResource: LazyAvatarRenderResource<AvatarTextureAtlas>",
            "private let clusterIconAtlasResource: LazyAvatarRenderResource<AvatarClusterIconAtlas>",
            "private let batteryBadgeAtlasResource: LazyAvatarRenderResource<AvatarBatteryBadgeAtlas>",
            "private let speedBadgeAtlasResource: LazyAvatarRenderResource<AvatarSpeedBadgeAtlas>"
        ]

        for declaration in declarations {
            XCTAssertTrue(source.contains(declaration), "Missing deferred atlas declaration: \(declaration)")
        }
    }

    func testRendererCleanupDoesNotInitializeAtlases() throws {
        let source = try rendererSource()

        XCTAssertTrue(source.contains("avatarAtlasResource.existingValue?.freeSlot(for: id)"))
        XCTAssertTrue(source.contains("if let clusterIconAtlas = clusterIconAtlasResource.existingValue"))
    }

    func testFrameRebuildRequestsAtlasesOnlyInsideNonEmptyItemLoops() throws {
        let source = try rendererSource()
        let rebuildStart = try XCTUnwrap(source.range(of: "private func rebuildFrameBuffers"))
        let rebuildEnd = try XCTUnwrap(source.range(of: "private func ensureFrameBufferCapacity"))
        let rebuildSource = source[rebuildStart.lowerBound..<rebuildEnd.lowerBound]

        let markerLoop = try XCTUnwrap(rebuildSource.range(of: "for item in layout.markerItems"))
        let avatarAtlasAccess = try XCTUnwrap(rebuildSource.range(of: "avatarAtlasResource.value"))
        XCTAssertLessThan(markerLoop.lowerBound, avatarAtlasAccess.lowerBound)

        let clusterLoop = try XCTUnwrap(rebuildSource.range(of: "for cluster in layout.clusterItems"))
        let clusterAtlasAccess = try XCTUnwrap(rebuildSource.range(of: "clusterIconAtlasResource.value"))
        XCTAssertLessThan(clusterLoop.lowerBound, clusterAtlasAccess.lowerBound)
    }

    func testEmptyDrawReturnsBeforeAnyAtlasAccess() throws {
        let source = try rendererSource()
        let drawStart = try XCTUnwrap(source.range(of: "func drawAvatars"))
        let drawSource = source[drawStart.lowerBound...]
        let emptyGuard = try XCTUnwrap(drawSource.range(of: "guard avatarCount > 0 || clusterCount > 0 else { return }"))
        let firstAtlasAccess = try XCTUnwrap(drawSource.range(of: "Resource.value"))

        XCTAssertLessThan(emptyGuard.lowerBound, firstAtlasAccess.lowerBound)
    }

    func testBadgeAtlasesAreRequestedOnlyAfterBadgePresenceCheck() throws {
        let source = try rendererSource()
        try assertAccess("batteryBadgeAtlasResource.value",
                         follows: "guard let badge = marker.batteryBadge else",
                         between: "private func makeBatteryBadgeInstance",
                         and: "private func makeSpeedBadgeInstance",
                         in: source)
        try assertAccess("speedBadgeAtlasResource.value",
                         follows: "guard let badge = marker.speedBadge else",
                         between: "private func makeSpeedBadgeInstance",
                         and: "private func rebuildFrameBuffers",
                         in: source)
    }

    private func assertAccess(_ access: String,
                              follows guardStatement: String,
                              between start: String,
                              and end: String,
                              in source: String) throws {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end,
                                                  range: startRange.upperBound..<source.endIndex))
        let functionSource = source[startRange.lowerBound..<endRange.lowerBound]
        let guardRange = try XCTUnwrap(functionSource.range(of: guardStatement))
        let accessRange = try XCTUnwrap(functionSource.range(of: access))
        XCTAssertLessThan(guardRange.lowerBound, accessRange.lowerBound)
    }

    private func rendererSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL.appendingPathComponent("ImmersiveMap/Render/Avatars/AvatarsRenderer.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

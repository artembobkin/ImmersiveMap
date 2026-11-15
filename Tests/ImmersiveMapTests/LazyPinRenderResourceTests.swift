// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class LazyPinRenderResourceTests: XCTestCase {
    private final class TestResource {}

    func testFactoryRunsOnlyOnFirstValueAccess() {
        var creationCount = 0
        let resource = LazyPinRenderResource {
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
        let resource = LazyPinRenderResource {
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
            "private let pinAtlasResource: LazyPinRenderResource<PinTextureAtlas>",
            "private let countBadgeAtlasResource: LazyPinRenderResource<PinCountBadgeAtlas>"
        ]

        for declaration in declarations {
            XCTAssertTrue(source.contains(declaration), "Missing deferred atlas declaration: \(declaration)")
        }
    }

    func testPinMutationsDoNotTouchAtlases() throws {
        // Pin mutations (apply/clear) must not touch the atlases:
        // images load lazily on visibility in rebuildFrameBuffers.
        let source = try rendererSource()
        let applyStart = try XCTUnwrap(source.range(of: "private func apply(snapshot:"))
        let applyEnd = try XCTUnwrap(source.range(of: "private func makeInstance"))
        let applySource = source[applyStart.lowerBound..<applyEnd.lowerBound]

        XCTAssertNil(applySource.range(of: "AtlasResource"),
                     "apply and clear must not touch the lazy atlases")
    }

    func testFrameRebuildGuardsEmptySceneBeforeAtlasAccess() throws {
        // An empty scene exits rebuildFrameBuffers before the first access to
        // a lazy atlas - a map without pins allocates no textures.
        let source = try rendererSource()
        let rebuildStart = try XCTUnwrap(source.range(of: "private func rebuildFrameBuffers"))
        let rebuildEnd = try XCTUnwrap(source.range(of: "private func ensureFrameBufferCapacity"))
        let rebuildSource = source[rebuildStart.lowerBound..<rebuildEnd.lowerBound]

        let emptyGuard = try XCTUnwrap(rebuildSource.range(of: "guard layout.pinItems.isEmpty == false"))
        let pinAtlasAccess = try XCTUnwrap(rebuildSource.range(of: "pinAtlasResource.value"))
        XCTAssertLessThan(emptyGuard.lowerBound, pinAtlasAccess.lowerBound)
    }

    func testEmptyDrawReturnsBeforeAnyAtlasAccess() throws {
        let source = try rendererSource()
        let drawStart = try XCTUnwrap(source.range(of: "func drawPins"))
        let drawSource = source[drawStart.lowerBound...]
        let emptyGuard = try XCTUnwrap(drawSource.range(of: "guard pinCount > 0 else { return }"))
        let firstAtlasAccess = try XCTUnwrap(drawSource.range(of: "Resource.value"))

        XCTAssertLessThan(emptyGuard.lowerBound, firstAtlasAccess.lowerBound)
    }

    func testTheBadgeAtlasIsRequestedOnlyAfterBadgePresenceCheck() throws {
        let source = try rendererSource()
        // The badge-presence check and the atlas access live in one guard
        // chain: short-circuiting guarantees the atlas is not created while
        // the pin has no badge.
        try assertAccess("countBadgeAtlasResource.value",
                         follows: "let badge = pin.countBadge",
                         between: "private func makeCountBadgeInstance",
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
        let sourceURL = packageRootURL.appendingPathComponent("Sources/ImmersiveMap/Pins/PinsRenderer.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

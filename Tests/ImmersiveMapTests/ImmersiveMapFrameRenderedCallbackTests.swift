// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import QuartzCore
import XCTest
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The `onFrameRendered` action through a real host view: display-link
/// updates are replayed against the view's frame delegate with a drawable
/// per update, the way `CAMetalDisplayLink` delivers them. Requires the
/// compiled Metal library, so it skips under `swift test` and runs in the
/// xcodebuild suites.
final class ImmersiveMapFrameRenderedCallbackTests: XCTestCase {
    @MainActor
    func testAScheduledFrameReportsOnceWithItsIndexAndTimestamp() throws {
        try skipUnlessMetalAvailable()
        let view = makeLaidOutHostView()
        var frames: [ImmersiveMapRenderedFrame] = []
        install(on: view) { frames.append($0) }

        view.requestFrame()
        try tick(view, targetPresentationTimestamp: 12.5)

        XCTAssertEqual(frames.count, 1, "One drawn frame is one event")
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame.targetPresentationTimestamp, 12.5,
                       "The event carries the update's target presentation timestamp")
        XCTAssertEqual(frame.frameIndex, try XCTUnwrap(view.rendererForTesting?.currentDiagnostics?.frameIndex),
                       "The event names the frame the renderer just drew")
        XCTAssertGreaterThanOrEqual(frame.cpuDuration, 0)

        view.requestFrame()
        try tick(view, targetPresentationTimestamp: 12.6)
        XCTAssertEqual(frames.map(\.frameIndex).count, 2)
        XCTAssertEqual(frames[1].frameIndex, frames[0].frameIndex + 1,
                       "Consecutive drawn frames count up by one")
    }

    @MainActor
    func testAnUpdateTheOnDemandLoopSkipsReportsNothing() throws {
        try skipUnlessMetalAvailable()
        let view = makeLaidOutHostView()
        var frames: [ImmersiveMapRenderedFrame] = []
        install(on: view) { frames.append($0) }

        view.requestFrame()
        try tick(view, targetPresentationTimestamp: 1)
        XCTAssertEqual(frames.count, 1)

        // Nothing asked for a frame: the loop draws nothing and says nothing.
        try tick(view, targetPresentationTimestamp: 2)
        XCTAssertEqual(frames.count, 1, "A skipped update is not a rendered frame")
    }

    @MainActor
    func testDismantleDropsTheAction() throws {
        try skipUnlessMetalAvailable()
        let view = makeLaidOutHostView()
        var frames: [ImmersiveMapRenderedFrame] = []
        install(on: view) { frames.append($0) }

        view.dismantle()
        view.requestFrame()
        try tick(view, targetPresentationTimestamp: 1)
        XCTAssertTrue(frames.isEmpty, "A dismantled view no longer reports to the app's action")
    }

    // MARK: - Support

    @MainActor
    private func makeLaidOutHostView() -> ImmersiveMapHostView {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 240)
        let view = ImmersiveMapHostView(frame: bounds, settings: FixtureTiles.tilelessSettings())
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #else
        view.layout()
        #endif
        return view
    }

    @MainActor
    private func install(on view: ImmersiveMapHostView,
                         action: @escaping (ImmersiveMapRenderedFrame) -> Void) {
        view.update(settings: FixtureTiles.tilelessSettings(),
                    avatarsController: nil,
                    cameraController: nil,
                    selectionController: nil,
                    avatarTapAction: nil,
                    frameRenderedAction: action,
                    markerContent: nil,
                    cameraPosition: nil)
    }

    /// One display-link update. The view's own layer is bound to its
    /// `CAMetalDisplayLink` and refuses `nextDrawable()`, so the drawable
    /// comes from a headless twin layer on the same device, the way the
    /// presentation-sync test renders; the delegate does not use the driver
    /// it is handed, so a detached one stands in for the view's own.
    @MainActor
    private func tick(_ view: ImmersiveMapHostView, targetPresentationTimestamp: CFTimeInterval) throws {
        let drawableLayer = CAMetalLayer()
        drawableLayer.device = view.metalLayer.device
        drawableLayer.pixelFormat = view.metalLayer.pixelFormat
        drawableLayer.drawableSize = view.metalLayer.drawableSize
        let drawable = try XCTUnwrap(drawableLayer.nextDrawable(), "The twin layer hands out drawables")
        let driver = ImmersiveMapRenderDriver(configuration: FixtureTiles.tilelessSettings().renderLoop)
        view.hostRuntimeForTesting.runtimeGraph.frameRenderDelegate.renderDriverDidTick(driver,
                                                                                         currentTime: targetPresentationTimestamp,
                                                                                         drawable: drawable)
    }

    private func skipUnlessMetalAvailable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? device.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
    }
}

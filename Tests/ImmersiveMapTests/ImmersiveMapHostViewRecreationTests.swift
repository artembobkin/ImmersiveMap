// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit
import Metal
import QuartzCore
import XCTest
@testable import ImmersiveMap

/// Integration on a real host view (requires compiled Metal, so the tests
/// skip under `swift test` and run fully under xcodebuild):
/// recreating the host view and the renderer must not break camera commands.
final class ImmersiveMapHostViewRecreationTests: XCTestCase {
    private let overview = ImmersiveMapCameraPosition(latitudeDegrees: 25,
                                                      longitudeDegrees: -30,
                                                      zoom: 1.7)
    private let tokyo = ImmersiveMapCameraPosition(latitudeDegrees: 35.6595,
                                                   longitudeDegrees: 139.7005,
                                                   zoom: 4.0)

    /// SwiftUI's order on identity change: first makeNSView of the new view,
    /// then dismantle of the old one. The camera must stay bound to the new one.
    @MainActor
    func testNewHostViewKeepsCameraAttachedWhenOldViewDismantlesAfter() throws {
        try skipUnlessMetalAvailable()

        let camera = ImmersiveMapCameraController()
        let oldView = makeHostView(camera: camera)
        let newView = makeHostView(camera: camera)

        oldView.dismantle()

        XCTAssertNotNil(camera.currentCameraPosition(),
                        "Dismantling the old view must not clear the cached camera position")

        var completed: Bool?
        camera.fly(to: tokyo, options: CameraFlightOptions(duration: 0.2)) { success in
            completed = success
        }
        XCTAssertTrue(newView.hasActiveCameraFlightForTesting,
                      "fly must reach the new host view")

        newView.advanceCameraFlightForTesting(currentTime: CACurrentMediaTime() + 1.0)
        XCTAssertEqual(completed, true)
        let position = try XCTUnwrap(camera.currentCameraPosition())
        XCTAssertEqual(position.zoom, tokyo.zoom, accuracy: 0.01)
        XCTAssertEqual(position.latitudeDegrees, tokyo.latitudeDegrees, accuracy: 0.01)
    }

    /// Recreating the renderer (debug panel toggle) finishes the active flight
    /// with success == false instead of silently swallowing the completion, and
    /// the next flight after recreation works.
    @MainActor
    func testRendererRecreationCompletesActiveFlightAndKeepsFlyWorking() throws {
        try skipUnlessMetalAvailable()

        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)

        var firstCompleted: Bool?
        camera.fly(to: tokyo, options: CameraFlightOptions(duration: 5.0)) { success in
            firstCompleted = success
        }
        XCTAssertTrue(view.hasActiveCameraFlightForTesting)

        view.update(settings: FixtureTiles.tilelessSettings().debugPanel(true),
                    avatarsController: nil,
                    cameraController: camera,
                    selectionController: nil,
                    avatarTapAction: nil,
                    markerContent: nil,
                    cameraPosition: overview)

        XCTAssertEqual(firstCompleted, false,
                       "Recreating the renderer must finish the flight, not leave it hanging")
        XCTAssertFalse(view.hasActiveCameraFlightForTesting)

        var secondCompleted: Bool?
        camera.fly(to: tokyo, options: CameraFlightOptions(duration: 0.2)) { success in
            secondCompleted = success
        }
        XCTAssertTrue(view.hasActiveCameraFlightForTesting,
                      "Flights must still work after the renderer is recreated")
        view.advanceCameraFlightForTesting(currentTime: CACurrentMediaTime() + 1.0)
        XCTAssertEqual(secondCompleted, true)
    }

    // MARK: - Helpers

    @MainActor
    private func makeHostView(camera: ImmersiveMapCameraController) -> ImmersiveMapNSView {
        let view = ImmersiveMapNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240),
                                      settings: FixtureTiles.tilelessSettings(),
                                      avatarsController: nil,
                                      cameraPosition: overview,
                                      cameraController: camera,
                                      selectionController: nil,
                                      avatarTapAction: nil)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        return view
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

#endif

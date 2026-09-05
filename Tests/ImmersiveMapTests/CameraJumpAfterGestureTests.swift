// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

@testable import ImmersiveMap
import Metal
import XCTest

/// A controller's `jump` goes where it says every time. It used to be
/// deduplicated against the last declared position, which a gesture never
/// updates, so a jump back to the previous jump's target after the user had
/// dragged the map away was dropped: a "recenter" button did nothing the
/// second time. The dedup stays on the SwiftUI modifier path alone, which
/// re-declares the same position on every update.
@MainActor
final class CameraJumpAfterGestureTests: XCTestCase {
    private let home = ImmersiveMapCameraPosition(latitudeDegrees: 52.52,
                                                  longitudeDegrees: 13.405,
                                                  zoom: 12,
                                                  bearing: 0,
                                                  pitch: 0)

    func testJumpBackToThePreviousTargetAfterAPanMovesTheCamera() throws {
        try skipUnlessMetalAvailable()
        let controller = ImmersiveMapCameraController()
        let view = makeHostView(cameraController: controller)
        defer { view.dismantle() }

        controller.jump(to: home)
        view.cameraRuntime.panCamera(deltaX: 200, deltaY: 120)
        let panned = try XCTUnwrap(view.cameraRuntime.currentCameraPosition())
        XCTAssertGreaterThan(abs(panned.latitudeDegrees - home.latitudeDegrees)
                             + abs(panned.longitudeDegrees - home.longitudeDegrees), 1e-4,
                             "the pan must have moved the camera for the test to mean anything")

        controller.jump(to: home)

        let after = try XCTUnwrap(view.cameraRuntime.currentCameraPosition())
        XCTAssertEqual(after.latitudeDegrees, home.latitudeDegrees, accuracy: 1e-6)
        XCTAssertEqual(after.longitudeDegrees, home.longitudeDegrees, accuracy: 1e-6)
    }

    func testDeclaredPositionRepeatedAfterAPanDoesNotSnapBack() throws {
        try skipUnlessMetalAvailable()
        let view = makeHostView(cameraController: nil)
        defer { view.dismantle() }
        view.update(settings: FixtureTiles.tilelessSettings(),
                    avatarsController: nil,
                    cameraController: nil,
                    selectionController: nil,
                    avatarTapAction: nil,
                    markerContent: nil,
                    cameraPosition: home)
        view.cameraRuntime.panCamera(deltaX: 200, deltaY: 120)
        let panned = try XCTUnwrap(view.cameraRuntime.currentCameraPosition())

        // SwiftUI re-declares the same position on its next update.
        view.update(settings: FixtureTiles.tilelessSettings(),
                    avatarsController: nil,
                    cameraController: nil,
                    selectionController: nil,
                    avatarTapAction: nil,
                    markerContent: nil,
                    cameraPosition: home)

        let after = try XCTUnwrap(view.cameraRuntime.currentCameraPosition())
        XCTAssertEqual(after.latitudeDegrees, panned.latitudeDegrees, accuracy: 1e-9)
        XCTAssertEqual(after.longitudeDegrees, panned.longitudeDegrees, accuracy: 1e-9)
    }

    private func makeHostView(cameraController: ImmersiveMapCameraController?) -> ImmersiveMapNSView {
        ImmersiveMapNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240),
                           settings: FixtureTiles.tilelessSettings(),
                           avatarsController: nil,
                           cameraPosition: nil,
                           cameraController: cameraController,
                           selectionController: nil,
                           avatarTapAction: nil)
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

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import XCTest

/// SwiftUI first creates the new representable, then dismantles the old one.
/// Controller detachment (camera, avatars, selection) must be strictly by
/// owner: dismantling a stale host view must not erase the attachment the new
/// view has already established for the same controller.
@MainActor
final class ImmersiveMapControllerReattachTests: XCTestCase {
    private final class Owner {}

    // MARK: - Camera

    func testStaleCameraDetachKeepsNewAttachmentAndPositionCache() {
        let camera = ImmersiveMapCameraController()
        let oldOwner = Owner()
        let newOwner = Owner()
        var oldHandled = 0
        var newHandled = 0
        camera.attachRuntime(owner: oldOwner) { _ in oldHandled += 1 }
        camera.attachRuntime(owner: newOwner) { _ in newHandled += 1 }
        camera.updateCurrentCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 25,
                                                                      longitudeDegrees: -30,
                                                                      zoom: 1.7))

        // The old view's dismantle arrives after the new one attaches.
        camera.detachRuntime(owner: oldOwner)

        camera.jump(to: ImmersiveMapCameraPosition(latitudeDegrees: 35.6595,
                                                   longitudeDegrees: 139.7005,
                                                   zoom: 4))
        XCTAssertEqual(newHandled, 1, "The command must reach the new owner")
        XCTAssertEqual(oldHandled, 0)
        XCTAssertNotNil(camera.currentCameraPosition(),
                        "Dismantling a stale view must not clear the cached position")
    }

    func testOwnedCameraDetachClearsHandlerAndQueuesCommandsForReplay() {
        let camera = ImmersiveMapCameraController()
        let owner = Owner()
        var handledBeforeDetach = 0
        camera.attachRuntime(owner: owner) { _ in handledBeforeDetach += 1 }

        camera.detachRuntime(owner: owner)
        camera.jump(to: ImmersiveMapCameraPosition(latitudeDegrees: 1,
                                                   longitudeDegrees: 2,
                                                   zoom: 3))
        XCTAssertEqual(handledBeforeDetach, 0,
                       "Once detached from its owner, commands queue up instead of running")

        var replayed = 0
        camera.attachRuntime(owner: owner) { _ in replayed += 1 }
        XCTAssertEqual(replayed, 1, "Reattaching replays the queued commands")
    }

    // MARK: - Avatars

    func testStaleAvatarDetachKeepsNewChangeHandler() throws {
        let avatars = ImmersiveMapAvatarsController()
        let oldOwner = Owner()
        let newOwner = Owner()
        var oldFired = 0
        var newFired = 0
        avatars.setChangeHandler({ oldFired += 1 }, owner: oldOwner)
        avatars.setChangeHandler({ newFired += 1 }, owner: newOwner)

        avatars.clearChangeHandler(ownedBy: oldOwner)

        avatars.add(AvatarMarker(id: 1,
                                 coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                                 image: try Self.makeTestImage()))
        XCTAssertGreaterThan(newFired, 0, "Changes must reach the new owner")
        XCTAssertEqual(oldFired, 0)
    }

    func testOwnedAvatarDetachClearsHandler() throws {
        let avatars = ImmersiveMapAvatarsController()
        let owner = Owner()
        var fired = 0
        avatars.setChangeHandler({ fired += 1 }, owner: owner)

        avatars.clearChangeHandler(ownedBy: owner)

        avatars.add(AvatarMarker(id: 1,
                                 coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                                 image: try Self.makeTestImage()))
        XCTAssertEqual(fired, 0)
    }

    // MARK: - Selection

    func testStaleSelectionDetachKeepsNewHandlerAndSelectionCache() {
        let selection = ImmersiveMapSelectionController()
        let oldOwner = Owner()
        let newOwner = Owner()
        var newReceived = 0
        selection.attachHandler(owner: oldOwner) { _ in
            XCTFail("A command must not reach a stale owner")
            return false
        }
        selection.attachHandler(owner: newOwner) { _ in
            newReceived += 1
            return true
        }
        selection.updateCurrentSelection(ImmersiveMapSelection(kind: .avatar, objectID: 7))

        selection.detachHandler(ownedBy: oldOwner)

        XCTAssertTrue(selection.select(ImmersiveMapSelection(kind: .avatar, objectID: 7)))
        XCTAssertEqual(newReceived, 1)
        XCTAssertNotNil(selection.currentSelection(),
                        "Dismantling a stale view must not clear the cached selection")
    }

    func testOwnedSelectionDetachClearsHandlerAndSelection() {
        let selection = ImmersiveMapSelectionController()
        let owner = Owner()
        selection.attachHandler(owner: owner) { _ in true }
        selection.updateCurrentSelection(ImmersiveMapSelection(kind: .avatar, objectID: 7))

        selection.detachHandler(ownedBy: owner)

        XCTAssertFalse(selection.select(ImmersiveMapSelection(kind: .avatar, objectID: 7)))
        XCTAssertNil(selection.currentSelection())
    }

    // MARK: - Helpers

    private static func makeTestImage() throws -> CGImage {
        let bytesPerRow = 4
        var data = Data(repeating: 0xff, count: bytesPerRow)
        let image = data.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(data: baseAddress,
                                          width: 1,
                                          height: 1,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            return context.makeImage()
        }
        return try XCTUnwrap(image)
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import XCTest

/// Merged markers: `merge` hides the members and shows a single marker with
/// averaged geo, a counter, and a cycling rotation of member images;
/// `unmerge` returns the members to the map.
final class AvatarMergedMarkersTests: XCTestCase {
    private let mergedID: UInt64 = 100

    func testMergeHidesMembersAndAddsMergedMarker() throws {
        let controller = ImmersiveMapAvatarsController()
        let imageA = try Self.makeTestImage(gray: 10)
        let imageB = try Self.makeTestImage(gray: 200)
        controller.add(AvatarMarker(id: 1, latitude: 10.0, longitude: 20.0, image: imageA))
        controller.add(AvatarMarker(id: 2, latitude: 12.0, longitude: 22.0, image: imageB))
        controller.add(AvatarMarker(id: 3, latitude: 50.0, longitude: 50.0, image: imageA))

        controller.merge(ids: [1, 2], mergedID: mergedID)

        let snapshot = try XCTUnwrap(controller.consumeSnapshot())
        let markerIDs = Set(snapshot.markers.map(\.id))
        XCTAssertEqual(markerIDs, [mergedID, 3])
        XCTAssertTrue(Set(snapshot.removedIds).isSuperset(of: [1, 2]),
                      "Members of a group must leave the map")

        let merged = try XCTUnwrap(snapshot.markers.first { $0.id == mergedID })
        XCTAssertEqual(merged.countBadge?.count, 2)
        XCTAssertTrue(merged.image === imageA, "The cycle starts with the first member's image")
        XCTAssertEqual(merged.coordinate.latitude, 11.0, accuracy: 0.05)
        XCTAssertEqual(merged.coordinate.longitude, 21.0, accuracy: 0.05)
    }

    func testMergedMarkerAveragesLiveMemberCoordinates() throws {
        let controller = try makeMergedController()
        _ = controller.consumeSnapshot()

        controller.move(id: 1, latitude: 30.0, longitude: 40.0)

        let snapshot = try XCTUnwrap(controller.consumeSnapshot())
        let merged = try XCTUnwrap(snapshot.markers.first { $0.id == mergedID })
        let expected = ImmersiveMapAvatarsController.averageCoordinate(of: [
            GeoCoordinate(latitude: 30.0, longitude: 40.0),
            GeoCoordinate(latitude: 12.0, longitude: 22.0)
        ])
        XCTAssertEqual(merged.coordinate.latitude, expected.latitude, accuracy: 1e-9)
        XCTAssertEqual(merged.coordinate.longitude, expected.longitude, accuracy: 1e-9)
    }

    func testAdvanceImageCycleSwitchesMemberImages() throws {
        let imageA = try Self.makeTestImage(gray: 10)
        let imageB = try Self.makeTestImage(gray: 200)
        let controller = try makeMergedController(imageA: imageA, imageB: imageB)
        _ = controller.consumeSnapshot()

        controller.advanceMergedImageCycle(mergedID: mergedID)
        var snapshot = try XCTUnwrap(controller.consumeSnapshot())
        var merged = try XCTUnwrap(snapshot.markers.first { $0.id == mergedID })
        XCTAssertTrue(merged.image === imageB, "The first step of the cycle shows the second member")

        controller.advanceMergedImageCycle(mergedID: mergedID)
        snapshot = try XCTUnwrap(controller.consumeSnapshot())
        merged = try XCTUnwrap(snapshot.markers.first { $0.id == mergedID })
        XCTAssertTrue(merged.image === imageA, "The cycle comes back to the first member")
    }

    func testImageCycleTimerAdvancesAutomatically() throws {
        let imageA = try Self.makeTestImage(gray: 10)
        let imageB = try Self.makeTestImage(gray: 200)
        let controller = ImmersiveMapAvatarsController()
        controller.add(AvatarMarker(id: 1, latitude: 10.0, longitude: 20.0, image: imageA))
        controller.add(AvatarMarker(id: 2, latitude: 12.0, longitude: 22.0, image: imageB))
        controller.merge(ids: [1, 2], mergedID: mergedID, imageCycleInterval: 0.05)
        _ = controller.consumeSnapshot()

        let cycled = expectation(description: "The cycle timer changed the merged marker's image")
        cycled.assertForOverFulfill = false
        controller.setChangeHandler({
            cycled.fulfill()
        }, owner: self)

        wait(for: [cycled], timeout: 2.0)
        let merged = try XCTUnwrap(controller.marker(id: mergedID))
        XCTAssertTrue(merged.image === imageB)
    }

    func testUnmergeRestoresMembers() throws {
        let controller = try makeMergedController()
        _ = controller.consumeSnapshot()

        controller.unmerge(mergedID: mergedID)

        let snapshot = try XCTUnwrap(controller.consumeSnapshot())
        XCTAssertEqual(Set(snapshot.markers.map(\.id)), [1, 2])
        XCTAssertTrue(snapshot.removedIds.contains(mergedID))
    }

    func testRemoveMergedMarkerRemovesMembers() throws {
        let controller = try makeMergedController()
        _ = controller.consumeSnapshot()

        controller.remove(id: mergedID)

        let snapshot = try XCTUnwrap(controller.consumeSnapshot())
        XCTAssertTrue(snapshot.markers.isEmpty)
        XCTAssertNil(controller.marker(id: 1))
        XCTAssertNil(controller.marker(id: 2))
        XCTAssertNil(controller.marker(id: mergedID))
    }

    func testRemoveMemberShrinksGroupAndDissolvesWhenEmpty() throws {
        let controller = try makeMergedController()
        _ = controller.consumeSnapshot()

        controller.remove(id: 2)
        var snapshot = try XCTUnwrap(controller.consumeSnapshot())
        var merged = try XCTUnwrap(snapshot.markers.first { $0.id == mergedID })
        XCTAssertEqual(merged.countBadge?.count, 1)
        XCTAssertEqual(controller.mergedMemberIDs(mergedID: mergedID), [1])

        controller.remove(id: 1)
        snapshot = try XCTUnwrap(controller.consumeSnapshot())
        XCTAssertTrue(snapshot.markers.isEmpty, "A group left empty is dissolved")
        XCTAssertNil(controller.mergedMemberIDs(mergedID: mergedID))
        _ = merged
    }

    func testUpdateMergedSelectionAffectsMergedMarker() throws {
        let controller = try makeMergedController()
        _ = controller.consumeSnapshot()

        controller.update(id: mergedID, isSelected: true)

        let merged = try XCTUnwrap(controller.marker(id: mergedID))
        XCTAssertTrue(merged.isSelected)
        XCTAssertEqual(merged.countBadge?.count, 2)
    }

    func testAverageCoordinateAcrossAntimeridian() {
        let average = ImmersiveMapAvatarsController.averageCoordinate(of: [
            GeoCoordinate(latitude: 0.0, longitude: 179.5),
            GeoCoordinate(latitude: 0.0, longitude: -179.5)
        ])

        XCTAssertEqual(abs(average.longitude), 180.0, accuracy: 0.01,
                       "An average across the antimeridian must not collapse to zero longitude")
        XCTAssertEqual(average.latitude, 0.0, accuracy: 0.01)
    }

    func testMergeIgnoresMembersOfOtherGroups() throws {
        let controller = try makeMergedController()
        let imageC = try Self.makeTestImage(gray: 120)
        controller.add(AvatarMarker(id: 3, latitude: 50.0, longitude: 50.0, image: imageC))
        _ = controller.consumeSnapshot()

        controller.merge(ids: [1, 3], mergedID: 200)

        XCTAssertEqual(controller.mergedMemberIDs(mergedID: 200), [3],
                       "A member of another group does not move into the new one")
        XCTAssertEqual(controller.mergedMemberIDs(mergedID: mergedID), [1, 2])
    }

    // MARK: - Helpers

    private func makeMergedController(imageA: CGImage? = nil,
                                      imageB: CGImage? = nil) throws -> ImmersiveMapAvatarsController {
        let controller = ImmersiveMapAvatarsController()
        controller.add(AvatarMarker(id: 1,
                                    latitude: 10.0,
                                    longitude: 20.0,
                                    image: try imageA ?? Self.makeTestImage(gray: 10)))
        controller.add(AvatarMarker(id: 2,
                                    latitude: 12.0,
                                    longitude: 22.0,
                                    image: try imageB ?? Self.makeTestImage(gray: 200)))
        controller.merge(ids: [1, 2], mergedID: mergedID, imageCycleInterval: 0)
        return controller
    }

    private static func makeTestImage(gray: UInt8) throws -> CGImage {
        let bytesPerRow = 4
        var data = Data([gray, gray, gray, 0xff])
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

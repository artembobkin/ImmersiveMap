// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

final class AvatarPresentationStateStoreTests: XCTestCase {
    /// The presented list goes in ascending id order, while draw order is given
    /// by the drawOrder field ranked by (drawPriority, id).
    func testPresentedEntriesAreIDOrderedWithDrawOrderRanks() throws {
        let store = AvatarPresentationStateStore()
        let markers = [
            try Self.makeMarker(id: 5, drawPriority: 0),
            try Self.makeMarker(id: 1, drawPriority: 2),
            try Self.makeMarker(id: 9, drawPriority: 1)
        ]
        store.apply(snapshot: Self.makeSnapshot(markers: markers), time: 0)

        let presented = store.presentedEntries(at: 0)
        XCTAssertEqual(presented.map(\.marker.id), [1, 5, 9])
        // Ranks by (drawPriority, id): (0, 5) -> 0, (1, 9) -> 1, (2, 1) -> 2.
        XCTAssertEqual(presented.map(\.drawOrder), [2, 0, 1])
    }

    /// Static markers are not rebuilt between mutations: repeated calls return
    /// the cache and report no animations.
    func testStaticMarkersReturnCachedListWithoutAnimations() throws {
        let store = AvatarPresentationStateStore()
        let markers = try (1...5).map { try Self.makeMarker(id: UInt64($0), drawPriority: 0) }
        store.apply(snapshot: Self.makeSnapshot(markers: markers), time: 0)

        let first = store.presentedEntries(at: 0.5)
        XCTAssertFalse(store.hasActiveAnimations)
        let second = store.presentedEntries(at: 1.0)
        XCTAssertEqual(first.map(\.marker.id), second.map(\.marker.id))
        XCTAssertEqual(first[2].marker.coordinate.latitude,
                       second[2].marker.coordinate.latitude)
    }

    /// A coordinate change animates the presentation and recomputes the projection
    /// basis; once the animations complete the store goes quiet.
    func testCoordinateChangeAnimatesAndRefreshesProjectionBasis() throws {
        let store = AvatarPresentationStateStore()
        var marker = try Self.makeMarker(id: 7, drawPriority: 0)
        store.apply(snapshot: Self.makeSnapshot(markers: [marker]), time: 0)
        _ = store.presentedEntries(at: 0)

        marker.coordinate = GeoCoordinate(latitude: 10.0, longitude: 20.0)
        store.apply(snapshot: Self.makeSnapshot(markers: [marker]), time: 1.0)
        XCTAssertTrue(store.hasActiveAnimations)

        // Mid-flight: the coordinate is between the start and the target.
        let midway = store.presentedEntries(at: 1.2)[0]
        XCTAssertGreaterThan(midway.marker.coordinate.latitude, 0.0)
        XCTAssertLessThan(midway.marker.coordinate.latitude, 10.0)

        // Enough time has passed: the marker is at the target, the basis matches
        // the coordinate, the animations have gone quiet.
        let settled = store.presentedEntries(at: 5.0)[0]
        XCTAssertEqual(settled.marker.coordinate.latitude, 10.0, accuracy: 1e-9)
        XCTAssertEqual(settled.marker.coordinate.longitude, 20.0, accuracy: 1e-9)
        let expectedBasis = GeoProjectionBasis(coordinate: settled.marker.coordinate)
        XCTAssertEqual(settled.projectionBasis.sphereUnit.x, expectedBasis.sphereUnit.x, accuracy: 1e-6)
        XCTAssertEqual(settled.projectionBasis.sphereUnit.y, expectedBasis.sphereUnit.y, accuracy: 1e-6)
        XCTAssertEqual(settled.projectionBasis.mercatorYNormalized,
                       expectedBasis.mercatorYNormalized,
                       accuracy: 1e-12)
        _ = store.presentedEntries(at: 5.1)
        XCTAssertFalse(store.hasActiveAnimations)
    }

    /// Markers removed from the snapshot disappear from the presented list.
    func testRemovedMarkersDisappearFromPresentedList() throws {
        let store = AvatarPresentationStateStore()
        let markers = try (1...3).map { try Self.makeMarker(id: UInt64($0), drawPriority: 0) }
        store.apply(snapshot: Self.makeSnapshot(markers: markers), time: 0)
        XCTAssertEqual(store.presentedEntries(at: 0).count, 3)

        store.apply(snapshot: Self.makeSnapshot(markers: [markers[1]]), time: 1)
        XCTAssertEqual(store.presentedEntries(at: 1).map(\.marker.id), [2])
    }

    // MARK: - Helpers

    private static func makeSnapshot(markers: [AvatarMarker]) -> AvatarsSnapshot {
        AvatarsSnapshot(markers: markers,
                        removedIds: [],
                        imageUpdateIds: [],
                        version: 1)
    }

    private static func makeMarker(id: UInt64, drawPriority: Int) throws -> AvatarMarker {
        AvatarMarker(id: id,
                     coordinate: GeoCoordinate(latitude: 0, longitude: Double(id)),
                     image: try makeTestImage(),
                     drawPriority: drawPriority)
    }

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

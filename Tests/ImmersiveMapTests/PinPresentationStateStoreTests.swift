// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

final class PinPresentationStateStoreTests: XCTestCase {
    /// The presented list goes in ascending id order, while draw order is given
    /// by the drawOrder field ranked by (drawPriority, id).
    func testPresentedEntriesAreIDOrderedWithDrawOrderRanks() throws {
        let store = PinPresentationStateStore()
        let pins = [
            try Self.makePin(id: 5, drawPriority: 0),
            try Self.makePin(id: 1, drawPriority: 2),
            try Self.makePin(id: 9, drawPriority: 1)
        ]
        store.apply(snapshot: Self.makeSnapshot(pins: pins), time: 0)

        let presented = store.presentedEntries(at: 0)
        XCTAssertEqual(presented.map(\.pin.id), [1, 5, 9])
        // Ranks by (drawPriority, id): (0, 5) -> 0, (1, 9) -> 1, (2, 1) -> 2.
        XCTAssertEqual(presented.map(\.drawOrder), [2, 0, 1])
    }

    /// Static pins are not rebuilt between mutations: repeated calls return
    /// the cache and report no animations.
    func testStaticPinsReturnCachedListWithoutAnimations() throws {
        let store = PinPresentationStateStore()
        let pins = try (1...5).map { try Self.makePin(id: UInt64($0), drawPriority: 0) }
        store.apply(snapshot: Self.makeSnapshot(pins: pins), time: 0)

        let first = store.presentedEntries(at: 0.5)
        XCTAssertFalse(store.hasActiveAnimations)
        let second = store.presentedEntries(at: 1.0)
        XCTAssertEqual(first.map(\.pin.id), second.map(\.pin.id))
        XCTAssertEqual(first[2].pin.coordinate.latitude,
                       second[2].pin.coordinate.latitude)
    }

    /// A coordinate change animates the presentation and recomputes the projection
    /// basis; once the animations complete the store goes quiet.
    func testCoordinateChangeAnimatesAndRefreshesProjectionBasis() throws {
        let store = PinPresentationStateStore()
        var pin = try Self.makePin(id: 7, drawPriority: 0)
        store.apply(snapshot: Self.makeSnapshot(pins: [pin]), time: 0)
        _ = store.presentedEntries(at: 0)

        pin.coordinate = GeoCoordinate(latitude: 10.0, longitude: 20.0)
        store.apply(snapshot: Self.makeSnapshot(pins: [pin]), time: 1.0)
        XCTAssertTrue(store.hasActiveAnimations)

        // Mid-flight: the coordinate is between the start and the target.
        let midway = store.presentedEntries(at: 1.2)[0]
        XCTAssertGreaterThan(midway.pin.coordinate.latitude, 0.0)
        XCTAssertLessThan(midway.pin.coordinate.latitude, 10.0)

        // Enough time has passed: the pin is at the target, the basis matches
        // the coordinate, the animations have gone quiet.
        let settled = store.presentedEntries(at: 5.0)[0]
        XCTAssertEqual(settled.pin.coordinate.latitude, 10.0, accuracy: 1e-9)
        XCTAssertEqual(settled.pin.coordinate.longitude, 20.0, accuracy: 1e-9)
        let expectedBasis = GeoProjectionBasis(coordinate: settled.pin.coordinate)
        XCTAssertEqual(settled.projectionBasis.sphereUnit.x, expectedBasis.sphereUnit.x, accuracy: 1e-6)
        XCTAssertEqual(settled.projectionBasis.sphereUnit.y, expectedBasis.sphereUnit.y, accuracy: 1e-6)
        XCTAssertEqual(settled.projectionBasis.mercatorYNormalized,
                       expectedBasis.mercatorYNormalized,
                       accuracy: 1e-12)
        _ = store.presentedEntries(at: 5.1)
        XCTAssertFalse(store.hasActiveAnimations)
    }

    /// Pins removed from the snapshot disappear from the presented list.
    func testRemovedPinsDisappearFromPresentedList() throws {
        let store = PinPresentationStateStore()
        let pins = try (1...3).map { try Self.makePin(id: UInt64($0), drawPriority: 0) }
        store.apply(snapshot: Self.makeSnapshot(pins: pins), time: 0)
        XCTAssertEqual(store.presentedEntries(at: 0).count, 3)

        store.apply(snapshot: Self.makeSnapshot(pins: [pins[1]]), time: 1)
        XCTAssertEqual(store.presentedEntries(at: 1).map(\.pin.id), [2])
    }

    // MARK: - Helpers

    private static func makeSnapshot(pins: [ImmersiveMapPin]) -> PinsSnapshot {
        PinsSnapshot(pins: pins,
                        removedIds: [],
                        imageUpdateIds: [],
                        version: 1)
    }

    private static func makePin(id: UInt64, drawPriority: Int) throws -> ImmersiveMapPin {
        ImmersiveMapPin(id: id,
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

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

final class AvatarPresentationStateStoreTests: XCTestCase {
    /// Presented-список идёт по возрастанию id, а порядок отрисовки задан
    /// полем drawOrder с рангом по (drawPriority, id).
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
        // Ранги по (drawPriority, id): (0, 5) -> 0, (1, 9) -> 1, (2, 1) -> 2.
        XCTAssertEqual(presented.map(\.drawOrder), [2, 0, 1])
    }

    /// Статичные маркеры между мутациями не пересобираются: повторные вызовы
    /// возвращают кеш и не сообщают об анимациях.
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

    /// Смена координаты анимирует показ и пересчитывает проекционный базис;
    /// по завершении анимаций стор затихает.
    func testCoordinateChangeAnimatesAndRefreshesProjectionBasis() throws {
        let store = AvatarPresentationStateStore()
        var marker = try Self.makeMarker(id: 7, drawPriority: 0)
        store.apply(snapshot: Self.makeSnapshot(markers: [marker]), time: 0)
        _ = store.presentedEntries(at: 0)

        marker.coordinate = GeoCoordinate(latitude: 10.0, longitude: 20.0)
        store.apply(snapshot: Self.makeSnapshot(markers: [marker]), time: 1.0)
        XCTAssertTrue(store.hasActiveAnimations)

        // Середина перелёта: координата между стартом и целью.
        let midway = store.presentedEntries(at: 1.2)[0]
        XCTAssertGreaterThan(midway.marker.coordinate.latitude, 0.0)
        XCTAssertLessThan(midway.marker.coordinate.latitude, 10.0)

        // Достаточно времени: маркер на цели, базис соответствует координате,
        // анимации затихли.
        let settled = store.presentedEntries(at: 5.0)[0]
        XCTAssertEqual(settled.marker.coordinate.latitude, 10.0, accuracy: 1e-9)
        XCTAssertEqual(settled.marker.coordinate.longitude, 20.0, accuracy: 1e-9)
        let expectedBasis = AvatarProjectionBasis(coordinate: settled.marker.coordinate)
        XCTAssertEqual(settled.projectionBasis.sphereUnit.x, expectedBasis.sphereUnit.x, accuracy: 1e-6)
        XCTAssertEqual(settled.projectionBasis.sphereUnit.y, expectedBasis.sphereUnit.y, accuracy: 1e-6)
        XCTAssertEqual(settled.projectionBasis.mercatorYNormalized,
                       expectedBasis.mercatorYNormalized,
                       accuracy: 1e-12)
        _ = store.presentedEntries(at: 5.1)
        XCTAssertFalse(store.hasActiveAnimations)
    }

    /// Удалённые из снапшота маркеры исчезают из presented-списка.
    func testRemovedMarkersDisappearFromPresentedList() throws {
        let store = AvatarPresentationStateStore()
        let markers = try (1...3).map { try Self.makeMarker(id: UInt64($0), drawPriority: 0) }
        store.apply(snapshot: Self.makeSnapshot(markers: markers), time: 0)
        XCTAssertEqual(store.presentedEntries(at: 0).count, 3)

        store.apply(snapshot: Self.makeSnapshot(markers: [markers[1]]), time: 1)
        XCTAssertEqual(store.presentedEntries(at: 1).map(\.marker.id), [2])
    }

    // MARK: - Хелперы

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

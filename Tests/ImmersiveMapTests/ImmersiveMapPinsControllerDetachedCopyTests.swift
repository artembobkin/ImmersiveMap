// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import XCTest

final class ImmersiveMapPinsControllerDetachedCopyTests: XCTestCase {
    private func makeImage() -> CGImage {
        let context = CGContext(data: nil,
                                width: 8,
                                height: 8,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    private func makePin(id: UInt64) -> ImmersiveMapPin {
        ImmersiveMapPin(id: id,
                     coordinate: GeoCoordinate(latitude: Double(id), longitude: Double(id)),
                     image: makeImage())
    }

    func testCopyCarriesFullPendingSnapshotAfterOriginalWasDrained() {
        let original = ImmersiveMapPinsController()
        original.add([makePin(id: 1), makePin(id: 2)])
        // The live engine consumes the pending diff...
        XCTAssertNotNil(original.consumeSnapshot())
        // ...after which the original has nothing pending anymore.
        XCTAssertNil(original.consumeSnapshot())

        let copy = original.makeDetachedCopyForExport()

        let snapshot = copy.consumeSnapshot()
        XCTAssertEqual(snapshot?.pins.map(\.id).sorted(), [1, 2])
        XCTAssertEqual(snapshot?.imageUpdateIds.sorted(), [1, 2],
                       "The export renderer must upload every image on first consume")
        XCTAssertNil(copy.consumeSnapshot(), "The full snapshot is consumed once")
    }

    func testCopyDoesNotDisturbTheOriginal() {
        let original = ImmersiveMapPinsController()
        original.add(makePin(id: 1))

        _ = original.makeDetachedCopyForExport()

        // The original's own pending diff is still intact for the live engine.
        let snapshot = original.consumeSnapshot()
        XCTAssertEqual(snapshot?.pins.map(\.id), [1])
    }

    func testCopyIsIsolatedFromLaterOriginalMutations() {
        let original = ImmersiveMapPinsController()
        original.add(makePin(id: 1))
        _ = original.consumeSnapshot()

        let copy = original.makeDetachedCopyForExport()
        original.add(makePin(id: 2))

        let copySnapshot = copy.consumeSnapshot()
        XCTAssertEqual(copySnapshot?.pins.map(\.id), [1],
                       "A mutation after the copy must not leak into the export")
        let originalSnapshot = original.consumeSnapshot()
        XCTAssertEqual(originalSnapshot?.pins.map(\.id).sorted(), [1, 2],
                       "The live engine keeps receiving its own diffs")
    }
}

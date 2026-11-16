// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// The pin hit-test must follow the collision-displaced bubble, not the
/// true geo point, and shrink together with the pin.
final class PinDisplacedSelectionTests: XCTestCase {
    private let pinSizePx: Float = 100.0

    func testHitTestFollowsDisplacedPosition() throws {
        let snapshot = try makeSnapshot(items: [
            makeItem(id: 1,
                     anchor: SIMD2(400, 300),
                     displaced: SIMD2(500, 300),
                     displayScale: 1.0)
        ])

        XCTAssertEqual(snapshot.hitTest(point: CGPoint(x: 500, y: 340)), .pin(1))
        XCTAssertNil(snapshot.hitTest(point: CGPoint(x: 400, y: 340)),
                     "The true anchor is empty once the pin is displaced: a tap there must not hit it")
    }

    func testHitRectShrinksWithDisplayScale() throws {
        let fullSnapshot = try makeSnapshot(items: [
            makeItem(id: 1,
                     anchor: SIMD2(400, 300),
                     displaced: SIMD2(400, 300),
                     displayScale: 1.0)
        ])
        let compressedSnapshot = try makeSnapshot(items: [
            makeItem(id: 1,
                     anchor: SIMD2(400, 300),
                     displaced: SIMD2(400, 300),
                     displayScale: 0.5)
        ])

        let probe = CGPoint(x: 440, y: 320)
        XCTAssertEqual(fullSnapshot.hitTest(point: probe), .pin(1))
        XCTAssertNil(compressedSnapshot.hitTest(point: probe),
                     "A shrunk pin takes less room, so its hit area must shrink with it")
    }

    // MARK: - Helpers

    private func makeSnapshot(items: [PinCollisionItem]) throws -> PinSelectionSnapshot {
        let projector = PinSelectionProjector()
        let pinStyle = PinStyle(sizePx: pinSizePx,
                                outlineWidthPx: 3.0)
        return projector.makeSnapshot(pinItems: items,
                                      drawSize: CGSize(width: 800, height: 600),
                                      pinStyle: pinStyle)
    }

    private func makeItem(id: UInt64,
                          anchor: SIMD2<Float>,
                          displaced: SIMD2<Float>,
                          displayScale: Float) -> PinCollisionItem {
        PinCollisionItem(pin: ImmersiveMapPin(id: id,
                                                       coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                                                       image: Self.testImage),
                                  squashScale: SIMD2<Float>(repeating: 1),
                                  screenPoint: ScreenPointOutput(position: displaced,
                                                                 depth: 0.5,
                                                                 visible: 1,
                                                                 visibilityAlpha: 1.0),
                                  anchorScreenPoint: ScreenPointOutput(position: anchor,
                                                                       depth: 0.5,
                                                                       visible: 1,
                                                                       visibilityAlpha: 1.0),
                                  displayScale: displayScale,
                                  morph: 0.0,
                                  isFlowerPetal: false,
                                  drawOrder: Int(id))
    }

    private static let testImage: CGImage = {
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
        return image!
    }()
}

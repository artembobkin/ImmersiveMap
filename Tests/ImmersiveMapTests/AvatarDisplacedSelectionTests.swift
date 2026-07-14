// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// Hit-test аватаров должен следовать за смещённым коллизиями пузырём, а не за
/// истинной геоточкой, и сжиматься вместе с маркером.
final class AvatarDisplacedSelectionTests: XCTestCase {
    private let markerSizePx: Float = 100.0

    func testHitTestFollowsDisplacedPosition() throws {
        let snapshot = try makeSnapshot(items: [
            makeItem(id: 1,
                     anchor: SIMD2(400, 300),
                     displaced: SIMD2(500, 300),
                     displayScale: 1.0)
        ])

        XCTAssertEqual(snapshot.hitTest(point: CGPoint(x: 500, y: 340)), .marker(1))
        XCTAssertNil(snapshot.hitTest(point: CGPoint(x: 400, y: 340)),
                     "Истинный якорь после смещения пуст: тап туда не должен попадать в маркер")
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
        XCTAssertEqual(fullSnapshot.hitTest(point: probe), .marker(1))
        XCTAssertNil(compressedSnapshot.hitTest(point: probe),
                     "Сжатый маркер занимает меньше места: широкая хит-зона должна сжаться")
    }

    // MARK: - Хелперы

    private func makeSnapshot(items: [AvatarCollisionMarkerItem]) throws -> AvatarSelectionSnapshot {
        let projector = AvatarSelectionProjector()
        let markerStyle = AvatarMarkerStyle(sizePx: markerSizePx,
                                            outlineWidthPx: 3.0,
                                            pointerHeightRatio: 0.15)
        return projector.makeSnapshot(markerItems: items,
                                      drawSize: CGSize(width: 800, height: 600),
                                      markerStyle: markerStyle,
                                      badgeStyle: AvatarBatteryBadgeStyle(sizePx: markerSizePx),
                                      speedBadgeStyle: AvatarSpeedBadgeStyle(sizePx: markerSizePx,
                                                                             markerStyle: markerStyle))
    }

    private func makeItem(id: UInt64,
                          anchor: SIMD2<Float>,
                          displaced: SIMD2<Float>,
                          displayScale: Float) -> AvatarCollisionMarkerItem {
        AvatarCollisionMarkerItem(marker: AvatarMarker(id: id,
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

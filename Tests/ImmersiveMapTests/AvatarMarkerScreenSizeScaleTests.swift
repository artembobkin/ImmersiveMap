// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import Foundation
import XCTest

final class AvatarMarkerScreenSizeScaleTests: XCTestCase {
    func testAvatarMarkerDefaultsToBaseScreenSizeScale() throws {
        let marker = AvatarMarker(id: 1,
                                  coordinate: GeoCoordinate(latitude: 55.7558, longitude: 37.6173),
                                  image: try Self.makeTestImage())

        XCTAssertEqual(marker.screenSizeScale, 1.0)
    }

    func testAvatarMarkerStoresCustomScreenSizeScale() throws {
        let marker = AvatarMarker(id: 1,
                                  coordinate: GeoCoordinate(latitude: 55.7558, longitude: 37.6173),
                                  image: try Self.makeTestImage(),
                                  screenSizeScale: 1.45)

        XCTAssertEqual(marker.screenSizeScale, 1.45)
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

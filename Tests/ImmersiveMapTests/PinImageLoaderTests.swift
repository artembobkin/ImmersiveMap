// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Foundation
import XCTest

final class PinImageLoaderTests: XCTestCase {
    func testDecodeCGImageReturnsImageForPNGData() throws {
        let image = try PinImageLoader.decodeCGImage(data: Self.onePixelPNGData)

        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 1)
    }

    func testDecodeCGImageThrowsForInvalidImageData() {
        XCTAssertThrowsError(try PinImageLoader.decodeCGImage(data: Data([0, 1, 2, 3]))) { error in
            XCTAssertEqual(error as? PinImageLoaderError, .cannotDecodeImage)
        }
    }

    private static let onePixelPNGData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/l8wQkwAAAABJRU5ErkJggg=="
    )!
}

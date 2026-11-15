// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class PinTextureRasterizerTests: XCTestCase {
    func testImageSizeWarningIsNilWhenSourceMatchesTargetSize() {
        let warning = PinTextureRasterizer.imageSizeWarning(sourceWidth: 128,
                                                              sourceHeight: 128,
                                                              targetWidth: 128,
                                                              targetHeight: 128)

        XCTAssertNil(warning)
    }

    func testImageSizeWarningReportsDifferentSquareSourceSize() throws {
        let warning = try XCTUnwrap(
            PinTextureRasterizer.imageSizeWarning(sourceWidth: 256,
                                                     sourceHeight: 256,
                                                     targetWidth: 128,
                                                     targetHeight: 128)
        )

        XCTAssertTrue(warning.contains("source 256x256"))
        XCTAssertTrue(warning.contains("expected 128x128"))
    }

    func testImageSizeWarningReportsNonSquareSourceSize() throws {
        let warning = try XCTUnwrap(
            PinTextureRasterizer.imageSizeWarning(sourceWidth: 256,
                                                     sourceHeight: 128,
                                                     targetWidth: 128,
                                                     targetHeight: 128)
        )

        XCTAssertTrue(warning.contains("source 256x128"))
        XCTAssertTrue(warning.contains("expected 128x128"))
    }
}

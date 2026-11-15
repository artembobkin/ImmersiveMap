// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
#if canImport(AppKit)
import AppKit
#endif
import XCTest

final class AvatarTextureRasterizerTests: XCTestCase {
    func testBatteryBadgeContentKeepsHorizontalPaddingAtDefaultWidth() {
        let markerSizePx = Float(ImmersiveMapSettings.AvatarSettings.Size.px64.rawValue) * ImmersiveMapSettings.default.avatars.sizeScale
        let style = AvatarBatteryBadgeStyle(sizePx: markerSizePx)

        XCTAssertGreaterThanOrEqual(Self.batteryBadgeHorizontalPadding(style: style), 5.0)
    }

    func testBatteryBadgeContentKeepsHorizontalPaddingWhenWidthUsesRatio() {
        let style = AvatarBatteryBadgeStyle(sizePx: 180.0)

        XCTAssertGreaterThanOrEqual(Self.batteryBadgeHorizontalPadding(style: style), 5.0)
    }

    func testSpeedBadgeUsesEnglishUnitText() {
        XCTAssertEqual(AvatarSpeedBadgeAtlas.unitText, "km/h")
    }

    func testImageSizeWarningIsNilWhenSourceMatchesTargetSize() {
        let warning = AvatarTextureRasterizer.imageSizeWarning(sourceWidth: 128,
                                                              sourceHeight: 128,
                                                              targetWidth: 128,
                                                              targetHeight: 128)

        XCTAssertNil(warning)
    }

    func testImageSizeWarningReportsDifferentSquareSourceSize() throws {
        let warning = try XCTUnwrap(
            AvatarTextureRasterizer.imageSizeWarning(sourceWidth: 256,
                                                     sourceHeight: 256,
                                                     targetWidth: 128,
                                                     targetHeight: 128)
        )

        XCTAssertTrue(warning.contains("source 256x256"))
        XCTAssertTrue(warning.contains("expected 128x128"))
    }

    func testImageSizeWarningReportsNonSquareSourceSize() throws {
        let warning = try XCTUnwrap(
            AvatarTextureRasterizer.imageSizeWarning(sourceWidth: 256,
                                                     sourceHeight: 128,
                                                     targetWidth: 128,
                                                     targetHeight: 128)
        )

        XCTAssertTrue(warning.contains("source 256x128"))
        XCTAssertTrue(warning.contains("expected 128x128"))
    }

    private static func batteryTextWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
#if canImport(AppKit)
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
#else
        return 0
#endif
    }

    private static func batteryBadgeHorizontalPadding(style: AvatarBatteryBadgeStyle) -> CGFloat {
        let layout = AvatarBatteryBadgeImageLayout(size: CGSize(width: CGFloat(style.sizePx.x),
                                                                height: CGFloat(style.sizePx.y)))
        let groupWidth = layout.targetIconHeight * (60.0 / 36.0)
            + layout.spacing
            + batteryTextWidth("100%", fontSize: layout.fontSize)
        return (layout.contentRect.width - groupWidth) * 0.5
    }
}

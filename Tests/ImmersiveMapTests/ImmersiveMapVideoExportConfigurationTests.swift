// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapVideoExportConfigurationTests: XCTestCase {
    func testDefaultsAreFullHD60HEVC() throws {
        let configuration = ImmersiveMapVideoExportConfiguration.default

        XCTAssertEqual(configuration.width, 1920)
        XCTAssertEqual(configuration.height, 1080)
        XCTAssertEqual(configuration.framesPerSecond, 60)
        XCTAssertEqual(configuration.codec, .hevc)
        XCTAssertNil(configuration.averageBitRate)
        XCTAssertEqual(configuration.tileReadinessTimeout, 10)
        XCTAssertNil(configuration.sceneDate)
        XCTAssertTrue(configuration.includesAvatars)
        XCTAssertTrue(configuration.includesMarkers)
        XCTAssertEqual(configuration.markerScale, 2.0)
        XCTAssertNoThrow(try configuration.validate())
    }

    func testOutOfRangeMarkerScaleIsRejected() {
        var tooSmall = ImmersiveMapVideoExportConfiguration.default
        tooSmall.markerScale = 0.4
        XCTAssertThrowsError(try tooSmall.validate())

        var tooLarge = ImmersiveMapVideoExportConfiguration.default
        tooLarge.markerScale = 9
        XCTAssertThrowsError(try tooLarge.validate())
    }

    func testOddDimensionsAreRejected() {
        var configuration = ImmersiveMapVideoExportConfiguration.default
        configuration.width = 1919

        XCTAssertThrowsError(try configuration.validate()) { error in
            guard case ImmersiveMapVideoExportError.invalidConfiguration = error else {
                return XCTFail("Expected invalidConfiguration, got \(error)")
            }
        }
    }

    func testOutOfRangeDimensionsAreRejected() {
        var tooSmall = ImmersiveMapVideoExportConfiguration.default
        tooSmall.height = 32
        XCTAssertThrowsError(try tooSmall.validate())

        var tooLarge = ImmersiveMapVideoExportConfiguration.default
        tooLarge.width = 16_384
        XCTAssertThrowsError(try tooLarge.validate())
    }

    func testNonPositiveFrameRateIsRejected() {
        var configuration = ImmersiveMapVideoExportConfiguration.default
        configuration.framesPerSecond = 0
        XCTAssertThrowsError(try configuration.validate())

        configuration.framesPerSecond = 240
        XCTAssertThrowsError(try configuration.validate())
    }

    func testNonPositiveBitRateAndTimeoutAreRejected() {
        var badBitRate = ImmersiveMapVideoExportConfiguration.default
        badBitRate.averageBitRate = 0
        XCTAssertThrowsError(try badBitRate.validate())

        var badTimeout = ImmersiveMapVideoExportConfiguration.default
        badTimeout.tileReadinessTimeout = 0
        XCTAssertThrowsError(try badTimeout.validate())
    }

    func testDefaultBitRateFollowsBitsPerPixelFormula() {
        let hevc = ImmersiveMapVideoExportConfiguration(width: 1920,
                                                        height: 1080,
                                                        framesPerSecond: 60,
                                                        codec: .hevc)
        XCTAssertEqual(hevc.resolvedAverageBitRate, Int(1920.0 * 1080.0 * 60.0 * 0.10))

        let h264 = ImmersiveMapVideoExportConfiguration(width: 1920,
                                                        height: 1080,
                                                        framesPerSecond: 60,
                                                        codec: .h264)
        XCTAssertEqual(h264.resolvedAverageBitRate, Int(1920.0 * 1080.0 * 60.0 * 0.20))

        var explicit = hevc
        explicit.averageBitRate = 5_000_000
        XCTAssertEqual(explicit.resolvedAverageBitRate, 5_000_000)
    }
}

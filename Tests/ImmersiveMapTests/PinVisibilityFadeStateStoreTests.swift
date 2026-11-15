// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import Foundation
import XCTest

final class PinVisibilityFadeStateStoreTests: XCTestCase {
    func testProjectedPinFadesOutWhenVisibilityAlphaDropsToZero() throws {
        let store = PinVisibilityFadeStateStore()
        let pin = try Self.makeProjectedPin(id: 1, visibilityAlpha: 1)
        _ = store.resolve(projectedPins: [pin],
                          time: 0,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)

        let hiddenPin = try Self.makeProjectedPin(id: 1, visibilityAlpha: 0)
        _ = store.resolve(projectedPins: [hiddenPin],
                          time: 0,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)
        let resolution = store.resolve(projectedPins: [hiddenPin],
                                       time: 0.125,
                                       fadeInSeconds: 0.15,
                                       fadeOutSeconds: 0.25)

        XCTAssertEqual(resolution.projectedPins.count, 1)
        XCTAssertEqual(resolution.projectedPins[0].screenPoint.visibilityAlpha, 0.5, accuracy: 0.0001)
        XCTAssertTrue(resolution.hasActiveAnimations)
    }

    func testProjectedPinIsRemovedAfterFadeOutCompletes() throws {
        let store = PinVisibilityFadeStateStore()
        let pin = try Self.makeProjectedPin(id: 1, visibilityAlpha: 1)
        _ = store.resolve(projectedPins: [pin],
                          time: 0,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)

        let hiddenPin = try Self.makeProjectedPin(id: 1, visibilityAlpha: 0)
        _ = store.resolve(projectedPins: [hiddenPin],
                          time: 0,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)
        let resolution = store.resolve(projectedPins: [hiddenPin],
                                       time: 0.3,
                                       fadeInSeconds: 0.15,
                                       fadeOutSeconds: 0.25)

        XCTAssertTrue(resolution.projectedPins.isEmpty)
        XCTAssertFalse(resolution.hasActiveAnimations)
    }

    func testProjectedPinFadesInWhenItReturnsAfterFadeOut() throws {
        let store = PinVisibilityFadeStateStore()
        let pin = try Self.makeProjectedPin(id: 1, visibilityAlpha: 1)
        let hiddenPin = try Self.makeProjectedPin(id: 1, visibilityAlpha: 0)

        _ = store.resolve(projectedPins: [pin],
                          time: 0,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)
        _ = store.resolve(projectedPins: [hiddenPin],
                          time: 0,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)
        _ = store.resolve(projectedPins: [hiddenPin],
                          time: 0.3,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)
        _ = store.resolve(projectedPins: [pin],
                          time: 0.3,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)
        let resolution = store.resolve(projectedPins: [pin],
                                       time: 0.375,
                                       fadeInSeconds: 0.15,
                                       fadeOutSeconds: 0.25)

        XCTAssertEqual(resolution.projectedPins.count, 1)
        XCTAssertEqual(resolution.projectedPins[0].screenPoint.visibilityAlpha, 0.5, accuracy: 0.0001)
        XCTAssertTrue(resolution.hasActiveAnimations)
    }

    private static func makeProjectedPin(id: UInt64,
                                            visibilityAlpha: Float) throws -> ProjectedPin {
        ProjectedPin(pin: try makePin(id: id),
                              squashScale: SIMD2<Float>(repeating: 1),
                              screenPoint: ScreenPointOutput(position: SIMD2<Float>(20, 30),
                                                             depth: 0.5,
                                                             visible: 1,
                                                             visibilityAlpha: visibilityAlpha),
                              drawOrder: 0)
    }

    private static func makePin(id: UInt64) throws -> ImmersiveMapPin {
        ImmersiveMapPin(id: id,
                     coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                     image: try makeTestImage())
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

// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import Foundation
import XCTest

final class AvatarVisibilityFadeStateStoreTests: XCTestCase {
    func testProjectedMarkerFadesOutWhenVisibilityAlphaDropsToZero() throws {
        let store = AvatarVisibilityFadeStateStore()
        let marker = try Self.makeProjectedMarker(id: 1, visibilityAlpha: 1)
        _ = store.resolve(projectedMarkers: [marker],
                          time: 0,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)

        let hiddenMarker = try Self.makeProjectedMarker(id: 1, visibilityAlpha: 0)
        _ = store.resolve(projectedMarkers: [hiddenMarker],
                          time: 0,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)
        let resolution = store.resolve(projectedMarkers: [hiddenMarker],
                                       time: 0.125,
                                       fadeInSeconds: 0.15,
                                       fadeOutSeconds: 0.25)

        XCTAssertEqual(resolution.projectedMarkers.count, 1)
        XCTAssertEqual(resolution.projectedMarkers[0].screenPoint.visibilityAlpha, 0.5, accuracy: 0.0001)
        XCTAssertTrue(resolution.hasActiveAnimations)
    }

    func testProjectedMarkerIsRemovedAfterFadeOutCompletes() throws {
        let store = AvatarVisibilityFadeStateStore()
        let marker = try Self.makeProjectedMarker(id: 1, visibilityAlpha: 1)
        _ = store.resolve(projectedMarkers: [marker],
                          time: 0,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)

        let hiddenMarker = try Self.makeProjectedMarker(id: 1, visibilityAlpha: 0)
        _ = store.resolve(projectedMarkers: [hiddenMarker],
                          time: 0,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)
        let resolution = store.resolve(projectedMarkers: [hiddenMarker],
                                       time: 0.3,
                                       fadeInSeconds: 0.15,
                                       fadeOutSeconds: 0.25)

        XCTAssertTrue(resolution.projectedMarkers.isEmpty)
        XCTAssertFalse(resolution.hasActiveAnimations)
    }

    func testProjectedMarkerFadesInWhenItReturnsAfterFadeOut() throws {
        let store = AvatarVisibilityFadeStateStore()
        let marker = try Self.makeProjectedMarker(id: 1, visibilityAlpha: 1)
        let hiddenMarker = try Self.makeProjectedMarker(id: 1, visibilityAlpha: 0)

        _ = store.resolve(projectedMarkers: [marker],
                          time: 0,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)
        _ = store.resolve(projectedMarkers: [hiddenMarker],
                          time: 0,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)
        _ = store.resolve(projectedMarkers: [hiddenMarker],
                          time: 0.3,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)
        _ = store.resolve(projectedMarkers: [marker],
                          time: 0.3,
                          fadeInSeconds: 0.15,
                          fadeOutSeconds: 0.25)
        let resolution = store.resolve(projectedMarkers: [marker],
                                       time: 0.375,
                                       fadeInSeconds: 0.15,
                                       fadeOutSeconds: 0.25)

        XCTAssertEqual(resolution.projectedMarkers.count, 1)
        XCTAssertEqual(resolution.projectedMarkers[0].screenPoint.visibilityAlpha, 0.5, accuracy: 0.0001)
        XCTAssertTrue(resolution.hasActiveAnimations)
    }

    private static func makeProjectedMarker(id: UInt64,
                                            visibilityAlpha: Float) throws -> AvatarProjectedMarker {
        AvatarProjectedMarker(marker: try makeMarker(id: id),
                              squashScale: SIMD2<Float>(repeating: 1),
                              screenPoint: ScreenPointOutput(position: SIMD2<Float>(20, 30),
                                                             depth: 0.5,
                                                             visible: 1,
                                                             visibilityAlpha: visibilityAlpha),
                              drawOrder: 0)
    }

    private static func makeMarker(id: UInt64) throws -> AvatarMarker {
        AvatarMarker(id: id,
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

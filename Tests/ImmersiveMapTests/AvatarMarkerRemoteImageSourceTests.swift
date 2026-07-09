// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import Foundation
import XCTest

final class AvatarMarkerRemoteImageSourceTests: XCTestCase {
    func testRemoteImageSourceInitializerStoresURLAndUsesPlaceholderImage() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/avatar.png"))

        let marker = AvatarMarker(id: 1,
                                  coordinate: GeoCoordinate(latitude: 55.7558, longitude: 37.6173),
                                  image: .remote(url))

        XCTAssertEqual(marker.imageSource.remoteURL, url)
        XCTAssertGreaterThan(marker.image.width, 0)
        XCTAssertGreaterThan(marker.image.height, 0)
    }

    func testAvatarsControllerLoadsRemoteImageAndPublishesImageUpdate() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/avatar.png"))
        let placeholderImage = try Self.makeTestImage(width: 1, height: 1)
        let loadedImage = try Self.makeTestImage(width: 2, height: 1)
        let loadStarted = expectation(description: "remote image load started")
        let updatePublished = expectation(description: "remote image update published")
        var loadContinuation: CheckedContinuation<CGImage, Never>?

        let controller = ImmersiveMapAvatarsController(imageLoader: { requestedURL in
            XCTAssertEqual(requestedURL, url)
            loadStarted.fulfill()
            return await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        })

        controller.add(
            AvatarMarker(id: 1,
                         coordinate: GeoCoordinate(latitude: 55.7558, longitude: 37.6173),
                         image: .remote(url, placeholder: placeholderImage))
        )

        await fulfillment(of: [loadStarted], timeout: 1.0)
        let initialSnapshot = try XCTUnwrap(controller.consumeSnapshot())
        XCTAssertEqual(initialSnapshot.markers.first?.image.width, 1)

        controller.setChangeHandler {
            updatePublished.fulfill()
        }
        loadContinuation?.resume(returning: loadedImage)

        await fulfillment(of: [updatePublished], timeout: 1.0)
        let updatedSnapshot = try XCTUnwrap(controller.consumeSnapshot())
        XCTAssertEqual(updatedSnapshot.markers.first?.image.width, 2)
        XCTAssertEqual(Set(updatedSnapshot.imageUpdateIds), [1])
    }

    private static func makeTestImage(width: Int, height: Int) throws -> CGImage {
        let bytesPerRow = width * 4
        var data = Data(repeating: 0xff, count: bytesPerRow * height)
        let image = data.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(data: baseAddress,
                                          width: width,
                                          height: height,
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

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit
import Metal
import XCTest
@testable import ImmersiveMap

final class ImmersiveMapNSViewTests: XCTestCase {
    @MainActor
    func testHostViewBuildsRuntimeAppliesLayoutAndAttachesCameraController() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        // swift test (SwiftPM CLI) не компилирует .metal в metallib - рендерер там не собрать;
        // под xcodebuild test шейдеры компилируются и тест выполняется целиком.
        guard (try? device.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }

        let camera = ImmersiveMapCameraController()
        let cameraPosition = ImmersiveMapCameraPosition(latitudeDegrees: 55.7558,
                                                        longitudeDegrees: 37.6173,
                                                        zoom: 3)
        let view = ImmersiveMapNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240),
                                      settings: .default,
                                      avatarsController: nil,
                                      cameraPosition: cameraPosition,
                                      cameraController: camera,
                                      selectionController: nil,
                                      markerTapAction: nil)

        XCTAssertTrue(view.layer is CAMetalLayer)
        XCTAssertTrue(view.isFlipped)

        view.needsLayout = true
        view.layoutSubtreeIfNeeded()

        let scale = view.metalLayer.contentsScale
        XCTAssertGreaterThanOrEqual(scale, 1.0)
        XCTAssertEqual(view.viewportRuntime.drawableSize,
                       CGSize(width: 320 * scale, height: 240 * scale))
        XCTAssertEqual(view.metalLayer.drawableSize, view.viewportRuntime.drawableSize)

        let attachedPosition = try XCTUnwrap(camera.currentCameraPosition())
        XCTAssertEqual(attachedPosition.zoom, cameraPosition.zoom, accuracy: 0.0001)

        // Клик по пустой карте доходит до camera callbacks через tap handler.
        var backgroundTapCount = 0
        camera.onMapBackgroundTap = { backgroundTapCount += 1 }
        view.simulateMapTapForTesting(at: CGPoint(x: 160, y: 120))
        XCTAssertEqual(backgroundTapCount, 1)
    }
}

#endif

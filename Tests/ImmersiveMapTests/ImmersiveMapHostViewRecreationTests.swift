// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit
import Metal
import QuartzCore
import XCTest
@testable import ImmersiveMap

/// Интеграция на реальном host view (нужен собранный Metal, поэтому
/// в `swift test` тесты скипаются, под xcodebuild выполняются целиком):
/// пересоздание host view и рендерера не должны ломать команды камеры.
final class ImmersiveMapHostViewRecreationTests: XCTestCase {
    private let overview = ImmersiveMapCameraPosition(latitudeDegrees: 25,
                                                      longitudeDegrees: -30,
                                                      zoom: 1.7)
    private let tokyo = ImmersiveMapCameraPosition(latitudeDegrees: 35.6595,
                                                   longitudeDegrees: 139.7005,
                                                   zoom: 4.0)

    /// Порядок SwiftUI при смене identity: сначала makeNSView нового view,
    /// затем dismantle старого. Камера обязана остаться привязанной к новому.
    @MainActor
    func testNewHostViewKeepsCameraAttachedWhenOldViewDismantlesAfter() throws {
        try skipUnlessMetalAvailable()

        let camera = ImmersiveMapCameraController()
        let oldView = makeHostView(camera: camera)
        let newView = makeHostView(camera: camera)

        oldView.dismantle()

        XCTAssertNotNil(camera.currentCameraPosition(),
                        "Демонтаж старого view не должен стирать кэш позиции камеры")

        var completed: Bool?
        camera.fly(to: tokyo, options: CameraFlightOptions(duration: 0.2)) { success in
            completed = success
        }
        XCTAssertTrue(newView.hasActiveCameraFlightForTesting,
                      "fly должен дойти до нового host view")

        newView.advanceCameraFlightForTesting(currentTime: CACurrentMediaTime() + 1.0)
        XCTAssertEqual(completed, true)
        let position = try XCTUnwrap(camera.currentCameraPosition())
        XCTAssertEqual(position.zoom, tokyo.zoom, accuracy: 0.01)
        XCTAssertEqual(position.latitudeDegrees, tokyo.latitudeDegrees, accuracy: 0.01)
    }

    /// Пересоздание рендерера (тоггл debug-панели) завершает активный перелёт
    /// с success == false вместо молчаливого проглатывания completion, и
    /// следующий перелёт после пересоздания работает.
    @MainActor
    func testRendererRecreationCompletesActiveFlightAndKeepsFlyWorking() throws {
        try skipUnlessMetalAvailable()

        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)

        var firstCompleted: Bool?
        camera.fly(to: tokyo, options: CameraFlightOptions(duration: 5.0)) { success in
            firstCompleted = success
        }
        XCTAssertTrue(view.hasActiveCameraFlightForTesting)

        view.update(settings: ImmersiveMapSettings.default.debugPanel(true),
                    avatarsController: nil,
                    cameraController: camera,
                    selectionController: nil,
                    avatarTapAction: nil,
                    markerContent: nil,
                    cameraPosition: overview)

        XCTAssertEqual(firstCompleted, false,
                       "Пересоздание рендерера должно завершить перелёт, а не подвесить его")
        XCTAssertFalse(view.hasActiveCameraFlightForTesting)

        var secondCompleted: Bool?
        camera.fly(to: tokyo, options: CameraFlightOptions(duration: 0.2)) { success in
            secondCompleted = success
        }
        XCTAssertTrue(view.hasActiveCameraFlightForTesting,
                      "После пересоздания рендерера перелёты должны работать")
        view.advanceCameraFlightForTesting(currentTime: CACurrentMediaTime() + 1.0)
        XCTAssertEqual(secondCompleted, true)
    }

    // MARK: - Хелперы

    @MainActor
    private func makeHostView(camera: ImmersiveMapCameraController) -> ImmersiveMapNSView {
        let view = ImmersiveMapNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240),
                                      settings: .default,
                                      avatarsController: nil,
                                      cameraPosition: overview,
                                      cameraController: camera,
                                      selectionController: nil,
                                      avatarTapAction: nil)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func skipUnlessMetalAvailable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? device.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
    }
}

#endif

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import SwiftUI
import XCTest

/// Тип дерева body не должен зависеть от `enableCameraUIControls`: смена
/// типа (ветки `_ConditionalContent`) заставляет SwiftUI уничтожить и
/// пересоздать весь платформенный map view вместе с рендерером и привязками
/// контроллеров.
@MainActor
final class ImmersiveMapViewBodyIdentityTests: XCTestCase {
    func testBodyTypeDoesNotDependOnCameraUIControlsToggle() {
        let camera = ImmersiveMapCameraController()
        let enabledType = String(describing: type(of: ImmersiveMapView()
            .camera(camera)
            .enableCameraUIControls(true)
            .body))
        let disabledType = String(describing: type(of: ImmersiveMapView()
            .camera(camera)
            .enableCameraUIControls(false)
            .body))
        let plainType = String(describing: type(of: ImmersiveMapView().body))

        XCTAssertEqual(enabledType, disabledType)
        XCTAssertEqual(enabledType, plainType)
        XCTAssertFalse(enabledType.contains("_ConditionalContent"),
                       "Ветвление по типу на верхнем уровне body ломает identity host view")
    }
}

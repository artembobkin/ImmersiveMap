// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import SwiftUI
import XCTest

/// The body tree type must not depend on `enableCameraUIControls`: a type
/// change (`_ConditionalContent` branches) forces SwiftUI to destroy and
/// recreate the entire platform map view along with the renderer and
/// controller bindings.
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
                       "Branching on type at the top level of body breaks the host view's identity")
    }

    func testBodyTypeDoesNotDependOnSceneModelsModifier() {
        let withModelsType = String(describing: type(of: ImmersiveMapView()
            .sceneModels(ImmersiveMapSceneModelsController())
            .body))
        let plainType = String(describing: type(of: ImmersiveMapView().body))

        XCTAssertEqual(withModelsType, plainType)
        XCTAssertFalse(withModelsType.contains("_ConditionalContent"),
                       "Branching on type at the top level of body breaks the host view's identity")
    }
}

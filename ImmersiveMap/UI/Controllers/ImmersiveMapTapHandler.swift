// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// Владеет обработкой tap-событий карты.
/// Отвечает за отсечение tap по control zones, selection hit-test и уведомление
/// camera API о background tap.
@MainActor
final class ImmersiveMapTapHandler {
    private let controlsRuntime: ImmersiveMapControlsRuntime
    private let selectionHandler: ImmersiveMapSelectionHandler
    private let cameraRuntime: ImmersiveMapCameraRuntime

    init(controlsRuntime: ImmersiveMapControlsRuntime,
         selectionHandler: ImmersiveMapSelectionHandler,
         cameraRuntime: ImmersiveMapCameraRuntime) {
        self.controlsRuntime = controlsRuntime
        self.selectionHandler = selectionHandler
        self.cameraRuntime = cameraRuntime
    }

    func handleBackgroundTap(at point: CGPoint) {
        guard controlsRuntime.containsControlPoint(point) == false else {
            return
        }

        cameraRuntime.notifyMapBackgroundTap()
    }

    func handleMapTap(at point: CGPoint) {
        guard controlsRuntime.containsControlPoint(point) == false else {
            return
        }

        switch selectionHandler.handleMapTap(at: point) {
        case .consumed:
            return
        case .background:
            cameraRuntime.notifyMapBackgroundTap()
        }
    }
}

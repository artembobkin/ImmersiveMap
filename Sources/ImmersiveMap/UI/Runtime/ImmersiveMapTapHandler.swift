// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// Owns map tap event handling.
/// Responsible for rejecting taps over control zones, the selection hit-test, and notifying
/// the camera API about background taps.
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

    /// Whether a feature of the map takes the double tap, or the
    /// secondary tap, as its own now (the tile grid, by its settings). The
    /// gesture recognizers ask before they treat the gesture as the
    /// camera's.
    func isClaimed(_ kind: MapTapKind) -> Bool {
        selectionHandler.isClaimed(kind)
    }

    /// A double tap or a secondary tap a feature has claimed.
    func handleClaimedTap(_ kind: MapTapKind, at point: CGPoint) {
        guard controlsRuntime.containsControlPoint(point) == false else {
            return
        }
        _ = selectionHandler.handleMapTap(at: point, kind: kind)
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

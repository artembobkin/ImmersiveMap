// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// A debug panel drawn over the map: the one the `ImmersiveMapDebug`
/// product ships, installed with `ImmersiveMapView.debugPanel(_:)`.
///
/// The engine keeps no panel of its own. It holds what a panel reads and
/// drags (`DebugOverlayControlState`, `DebugOverlayHUDSnapshotStore`) and
/// the slot this fills (`ImmersiveMapRuntimeGraph.installDebugPanel`), so
/// an app that links `ImmersiveMap` alone carries nothing of the panel's
/// views. The value is opaque to an app: only a target of this package
/// can make one (`makeRuntime` is `package`), and `ImmersiveMapDebug`
/// offers its panel as a static of this type.
public struct ImmersiveMapDebugPanel: Sendable {
    /// Makes the panel's runtime over the host the engine hands it, once
    /// per host view.
    package let makeRuntime: @MainActor @Sendable (ImmersiveMapDebugPanelHost) -> any ImmersiveMapDebugPanelRuntime

    package init(makeRuntime: @escaping @MainActor @Sendable (ImmersiveMapDebugPanelHost) -> any ImmersiveMapDebugPanelRuntime) {
        self.makeRuntime = makeRuntime
    }
}

/// What the engine hands a debug panel to work with: the view to lay
/// itself into, the controls it drags and the stores it reads, and the
/// runtimes it asks for a frame or a surface switch. Made for the one
/// call that installs a panel and kept by nothing: the view owns the
/// engine's runtimes, so a runtime that stored this would keep the view
/// alive after it was dismantled.
@MainActor
package struct ImmersiveMapDebugPanelHost {
    package let mapView: ImmersiveMapHostView
    package let controls: DebugOverlayControlState
    package let hudSnapshotStore: DebugOverlayHUDSnapshotStore
    package let tileTraceRecorder: TileTraceRecorder
    package let baseLabelTraceRecorder: BaseLabelTraceRecorder
    package let renderRuntime: ImmersiveMapRenderRuntime
    package let cameraRuntime: ImmersiveMapCameraRuntime
    package let cameraAnimationRuntime: ImmersiveMapCameraAnimationRuntime
}

/// What the engine asks of an installed debug panel
/// (`ImmersiveMapHostRuntime`, the host views).
@MainActor
package protocol ImmersiveMapDebugPanelRuntime: AnyObject {
    /// Settings the panel asks for. The host runtime applies them the way
    /// it applies any others, so a change here goes through the same
    /// planner (and the same renderer-rebuild decision) as one made in
    /// SwiftUI.
    var onSettingsChangeRequested: ((ImmersiveMapSettings) -> Void)? { get set }
    /// The settings the map should actually run with: the ones it was
    /// given, with whatever the panel has been dragged to on top.
    func applyingOverrides(to settings: ImmersiveMapSettings) -> ImmersiveMapSettings
    /// The settings the map runs with, for the panel to show.
    func apply(settings: ImmersiveMapSettings)
    /// The host view's bounds, for the panel to lay itself out in.
    func layout(in bounds: CGRect, safeAreaTopInset: CGFloat)
}

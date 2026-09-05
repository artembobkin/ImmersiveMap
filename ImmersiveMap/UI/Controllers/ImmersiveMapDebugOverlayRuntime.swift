// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

@MainActor
final class ImmersiveMapDebugOverlayRuntime {
    private let hudView = DebugOverlayHUDView()
    private let controls: DebugOverlayControlState
    private let hudSnapshotStore: DebugOverlayHUDSnapshotStore
    private let tileTraceRecorder: TileTraceRecorder
    private let baseLabelTraceRecorder: BaseLabelTraceRecorder
    private weak var renderRuntime: ImmersiveMapRenderRuntime?
    // nonisolated(unsafe): the timer is created and invalidated on main, but
    // deinit is nonisolated in Swift 6 - access is safe, the object lives only
    // on main.
    nonisolated(unsafe) private var hudSnapshotTimer: Timer?
    private var consumedHUDSnapshotVersion: UInt64 = 0
    /// The settings the map is running with, so the panel can hand back a
    /// whole value with one branch changed.
    private var currentSettings: ImmersiveMapSettings?
    /// What the panel has been dragged to; see `DebugOverlaySettingsOverride`.
    private var settingsOverride = DebugOverlaySettingsOverride()

    /// Settings the debug panel asks for. The host runtime applies them the
    /// way it applies any others, so a change here goes through the same
    /// planner (and the same renderer-rebuild decision) as one made in SwiftUI.
    /// A later `update(settings:)` from the view hierarchy overrides it, which
    /// is correct: the app's own value is the source of truth, and the panel
    /// only borrows it between updates.
    var onSettingsChangeRequested: ((ImmersiveMapSettings) -> Void)?

    init(mapView: ImmersiveMapHostView,
         controls: DebugOverlayControlState,
         hudSnapshotStore: DebugOverlayHUDSnapshotStore,
         tileTraceRecorder: TileTraceRecorder,
         baseLabelTraceRecorder: BaseLabelTraceRecorder,
         renderRuntime: ImmersiveMapRenderRuntime,
         cameraRuntime: ImmersiveMapCameraRuntime,
         cameraAnimationRuntime: ImmersiveMapCameraAnimationRuntime) {
        self.controls = controls
        self.hudSnapshotStore = hudSnapshotStore
        self.tileTraceRecorder = tileTraceRecorder
        self.baseLabelTraceRecorder = baseLabelTraceRecorder
        self.renderRuntime = renderRuntime
        hudView.onAxesEnabledChanged = { [weak controls, weak renderRuntime] isEnabled in
            controls?.setAxesEnabled(isEnabled)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onTileLayersEnabledChanged = { [weak controls, weak renderRuntime] isEnabled in
            controls?.setTileLayersEnabled(isEnabled)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onTileGridEnabledChanged = { [weak controls, weak renderRuntime] isEnabled in
            controls?.setTileGridEnabled(isEnabled)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onTileGridDensityChanged = { [weak controls, weak renderRuntime] density in
            controls?.setTileGridDensity(density)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onWireframeEnabledChanged = { [weak controls, weak renderRuntime] isEnabled in
            controls?.setWireframeEnabled(isEnabled)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onRoadLabelTilesEnabledChanged = { [weak controls, weak renderRuntime] isEnabled in
            controls?.setRoadLabelTilesEnabled(isEnabled)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onBaseLabelBoundsEnabledChanged = { [weak controls, weak renderRuntime] isEnabled in
            controls?.setBaseLabelBoundsEnabled(isEnabled)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onRoadLabelBoundsEnabledChanged = { [weak controls, weak renderRuntime] isEnabled in
            controls?.setRoadLabelBoundsEnabled(isEnabled)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onSurfaceModeSwitchRequested = { [weak cameraRuntime, weak cameraAnimationRuntime] in
            cameraAnimationRuntime?.cancelAnimations()
            cameraRuntime?.switchRenderMode()
        }
        hudView.onTileTraceRecordingToggle = { [weak self, weak renderRuntime] in
            guard let self else { return }
            if tileTraceRecorder.snapshot().isRecording {
                tileTraceRecorder.stopRecording()
            } else {
                _ = tileTraceRecorder.startRecording()
            }
            hudView.apply(tileTraceSnapshot: tileTraceRecorder.snapshot())
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onBaseLabelTraceRecordingToggle = { [weak self, weak renderRuntime] in
            guard let self else { return }
            if baseLabelTraceRecorder.snapshot().isRecording {
                baseLabelTraceRecorder.stopRecording()
            } else {
                _ = baseLabelTraceRecorder.startRecording()
            }
            hudView.apply(baseLabelTraceSnapshot: baseLabelTraceRecorder.snapshot())
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        #if os(macOS)
        // The shadow group is part of the reworked AppKit panel; the UIKit one
        // still carries the tabbed layout and has no such group yet.
        hudView.onShadowSettingsChanged = { [weak self] shadows in
            guard let self, var settings = currentSettings else { return }
            settingsOverride.shadows = shadows
            settings.scene.shadows = shadows
            onSettingsChangeRequested?(settings)
        }
        hudView.onSunDirectionChanged = { [weak self] direction in
            guard let self, var settings = currentSettings else { return }
            settingsOverride.sunDirection = direction
            settings.scene.light.direction = direction
            onSettingsChangeRequested?(settings)
        }
        #endif
        hudView.apply(tileTraceSnapshot: tileTraceRecorder.snapshot())
        hudView.apply(baseLabelTraceSnapshot: baseLabelTraceRecorder.snapshot())
        mapView.addSubview(hudView)
    }

    deinit {
        hudSnapshotTimer?.invalidate()
    }

    /// The settings the map should actually run with: the ones it was given,
    /// with whatever the debug panel has been dragged to on top. Turning the
    /// panel off drops the overrides, so the app's own values come straight
    /// back.
    func applyingOverrides(to settings: ImmersiveMapSettings) -> ImmersiveMapSettings {
        if settings.debug.enableDebugPanel == false {
            settingsOverride.clear()
        }
        return settingsOverride.applied(to: settings)
    }

    func layout(in bounds: CGRect, safeAreaTopInset: CGFloat) {
        hudView.safeAreaTopInset = safeAreaTopInset
        hudView.frame = bounds
    }

    func apply(snapshot: DebugOverlayHUDSnapshot?) {
        hudSnapshotStore.publish(snapshot)
        flushPendingHUDSnapshot()
    }

    func apply(settings: ImmersiveMapSettings) {
        currentSettings = settings
        hudView.apply(isDebugPanelEnabled: settings.debug.enableDebugPanel,
                      controls: controls.snapshot())
        #if os(macOS)
        hudView.apply(shadowSettings: settings.scene.shadows,
                      sunDirection: settings.scene.light.direction)
        #endif
        hudView.apply(tileTraceSnapshot: tileTraceRecorder.snapshot())
        hudView.apply(baseLabelTraceSnapshot: baseLabelTraceRecorder.snapshot())
        if settings.debug.enableDebugPanel {
            startHUDSnapshotTimer()
            flushPendingHUDSnapshot()
        } else {
            stopHUDSnapshotTimer()
            consumedHUDSnapshotVersion = hudSnapshotStore.publish(nil)
            hudView.apply(snapshot: nil)
        }
    }

    private func startHUDSnapshotTimer() {
        guard hudSnapshotTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: DebugOverlayHUDSnapshotThrottler.defaultMinimumInterval,
                          repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushPendingHUDSnapshot()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hudSnapshotTimer = timer
    }

    private func stopHUDSnapshotTimer() {
        hudSnapshotTimer?.invalidate()
        hudSnapshotTimer = nil
    }

    private func flushPendingHUDSnapshot() {
        guard let value = hudSnapshotStore.consumeLatest(after: consumedHUDSnapshotVersion) else {
            return
        }

        consumedHUDSnapshotVersion = value.version
        hudView.apply(snapshot: value.snapshot)
    }
}

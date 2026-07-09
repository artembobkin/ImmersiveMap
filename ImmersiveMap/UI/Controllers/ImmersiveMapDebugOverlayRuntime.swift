// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import Foundation
import UIKit

@MainActor
final class ImmersiveMapDebugOverlayRuntime {
    private let hudView = DebugOverlayHUDView()
    private let controls: DebugOverlayControlState
    private let hudSnapshotStore: DebugOverlayHUDSnapshotStore
    private let tileTraceRecorder: TileTraceRecorder
    private let baseLabelTraceRecorder: BaseLabelTraceRecorder
    private weak var renderRuntime: ImmersiveMapRenderRuntime?
    private var hudSnapshotTimer: Timer?
    private var consumedHUDSnapshotVersion: UInt64 = 0

    init(mapView: ImmersiveMapUIView,
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
        hudView.onWireframeEnabledChanged = { [weak controls, weak renderRuntime] isEnabled in
            controls?.setWireframeEnabled(isEnabled)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onTerrainEnabledChanged = { [weak controls, weak renderRuntime] isEnabled in
            controls?.setTerrainEnabled(isEnabled)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onRoadLabelTilesEnabledChanged = { [weak controls, weak renderRuntime] isEnabled in
            controls?.setRoadLabelTilesEnabled(isEnabled)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onEarthSceneEnabledChanged = { [weak mapView] isEnabled in
            mapView?.setEarthSceneEnabledFromDebugOverlay(isEnabled)
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
        hudView.apply(tileTraceSnapshot: tileTraceRecorder.snapshot())
        hudView.apply(baseLabelTraceSnapshot: baseLabelTraceRecorder.snapshot())
        mapView.addSubview(hudView)
    }

    deinit {
        hudSnapshotTimer?.invalidate()
    }

    func layout(in bounds: CGRect) {
        hudView.frame = bounds
    }

    func apply(snapshot: DebugOverlayHUDSnapshot?) {
        hudSnapshotStore.publish(snapshot)
        flushPendingHUDSnapshot()
    }

    func apply(settings: ImmersiveMapSettings) {
        hudView.apply(isDebugPanelEnabled: settings.debug.enableDebugPanel,
                      controls: controls.snapshot(),
                      earthSceneEnabled: settings.scene.earth.isEnabled)
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

#endif

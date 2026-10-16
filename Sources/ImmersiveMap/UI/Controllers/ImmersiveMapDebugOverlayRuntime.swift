// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#endif

@MainActor
final class ImmersiveMapDebugOverlayRuntime {
    private let hudView = DebugOverlayHUDView()
    /// The panel's zoom badge (`DebugSettings.showsZoomBadge`), read off
    /// the same snapshots, laid out in the map's corner.
    private let zoomBadgeView = DebugOverlayZoomBadgeView()
    private var showsZoomBadge = false
    private var layoutBounds: CGRect = .zero
    private var layoutTopInset: CGFloat = 0
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
    /// What the panel shows right now: the base a between-frames refresh
    /// of the tile list is built on.
    private var appliedHUDSnapshot: DebugOverlayHUDSnapshot?
    /// The settings the map is running with, so the panel can hand back a
    /// whole value with one branch changed.
    private var currentSettings: ImmersiveMapSettings?
    /// What the panel has been dragged to; see `DebugOverlaySettingsOverride`.
    private var settingsOverride = DebugOverlaySettingsOverride()
    /// The ground fog the app gave, for the ground fog group's reset: the
    /// value of any settings that did not come from the panel's own drag.
    private var appGroundFog: ImmersiveMapSettings.GroundFogSettings?

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
        hudSnapshotStore.onSnapshotPublished = { [weak self] in
            self?.flushPendingHUDSnapshot()
        }
        hudSnapshotStore.onTileLoadingStatusChanged = { [weak self] in
            self?.refreshTileLoadingStatusBetweenFrames()
        }
        hudSnapshotStore.requestedContent = hudView.shownContent
        hudView.onShownContentChanged = { [weak hudSnapshotStore, weak renderRuntime] content in
            // The tab just opened fills on the next frame, requested here,
            // rather than on the next move of the camera.
            hudSnapshotStore?.requestedContent = content
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
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
        // still carries the tabbed layout and has no such group yet. The
        // ring rules are bench controls of the same panel.
        hudView.onRingRuleSetsChanged = { [weak controls, weak renderRuntime] sets in
            controls?.setRingRuleSets(sets)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onLabelDistanceRulesChanged = { [weak controls, weak renderRuntime] rules in
            controls?.setLabelDistanceRules(rules)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onLocalLabelDistanceChanged = { [weak controls, weak renderRuntime] meters in
            controls?.setLocalLabelMaximumDistanceMeters(meters)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onLabelMinimumScaleChanged = { [weak controls, weak renderRuntime] scale in
            controls?.setLabelPerspectiveMinimumScale(scale)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onHillshadeFadeChanged = { [weak controls, weak renderRuntime] fade in
            controls?.setHillshadeFadeCameraDistances(fade)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
        hudView.onReliefShadowsChanged = { [weak controls, weak renderRuntime] isEnabled in
            controls?.setReliefCastsShadows(isEnabled)
            renderRuntime?.requestFrame(reason: .externalStateChanged)
        }
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
        hudView.onFogSettingsChanged = { [weak self] fog in
            guard let self, var settings = currentSettings else { return }
            settingsOverride.fog = fog
            settings.scene.fog = fog
            onSettingsChangeRequested?(settings)
        }
        hudView.onAtmosphereSettingsChanged = { [weak self] atmosphere in
            guard let self, var settings = currentSettings else { return }
            settingsOverride.atmosphere = atmosphere
            settings.scene.atmosphere = atmosphere
            onSettingsChangeRequested?(settings)
        }
        hudView.onGroundFogSettingsChanged = { [weak self] groundFog in
            guard let self, var settings = currentSettings else { return }
            settingsOverride.groundFog = groundFog
            settings.scene.groundFog = groundFog
            onSettingsChangeRequested?(settings)
        }
        hudView.onGroundFogResetRequested = { [weak self] in
            guard let self, var settings = currentSettings else { return }
            settingsOverride.groundFog = nil
            settings.scene.groundFog = appGroundFog ?? settings.scene.groundFog
            onSettingsChangeRequested?(settings)
        }
        hudView.onExportSettingsRequested = { [weak self] in
            self?.exportSettings()
        }
        #endif
        hudView.apply(tileTraceSnapshot: tileTraceRecorder.snapshot())
        hudView.apply(baseLabelTraceSnapshot: baseLabelTraceRecorder.snapshot())
        mapView.addSubview(hudView)
        mapView.addSubview(zoomBadgeView)
    }

    #if os(macOS)
    /// The Export tab's button: the settings the map runs with, as the
    /// modifiers that set them, written to the Downloads folder (the
    /// temporary folder where it cannot be written), and the file's path put
    /// on the pasteboard so it can be pasted at once.
    private func exportSettings() {
        guard let settings = currentSettings else { return }
        let date = Date()
        let cameraLines = appliedHUDSnapshot.map { [$0.coordinateLines.zoom, $0.coordinateLines.latLon] } ?? []
        let text = DebugOverlaySettingsExport.swiftCode(settings: settings, date: date, cameraLines: cameraLines)
        let fileName = DebugOverlaySettingsExport.fileName(date: date)
        let folders = [FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
                       FileManager.default.temporaryDirectory].compactMap { $0 }
        for folder in folders {
            let url = folder.appendingPathComponent(fileName)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                continue
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
            hudView.apply(exportStatus: "Saved, path copied:\n\(url.path)")
            return
        }
        hudView.apply(exportStatus: "Could not write the file to Downloads or the temporary folder")
    }
    #endif

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
        // The panel's own request carries the dragged fog. Anything else
        // carries the app's.
        if settingsOverride.groundFog != settings.scene.groundFog {
            appGroundFog = settings.scene.groundFog
        }
        return settingsOverride.applied(to: settings)
    }

    func layout(in bounds: CGRect, safeAreaTopInset: CGFloat) {
        hudView.safeAreaTopInset = safeAreaTopInset
        hudView.frame = bounds
        layoutBounds = bounds
        layoutTopInset = safeAreaTopInset
        zoomBadgeView.layout(in: bounds, topInset: safeAreaTopInset)
    }

    /// The badge on the panel's snapshot: shown with the panel while it
    /// asks for it, hidden without a snapshot to read.
    private func applyZoomBadge(_ snapshot: DebugOverlayHUDSnapshot?) {
        guard showsZoomBadge, let snapshot else {
            zoomBadgeView.isHidden = true
            return
        }
        zoomBadgeView.apply(zoom: snapshot.zoom, planningZoom: snapshot.cameraZoom)
        zoomBadgeView.layout(in: layoutBounds, topInset: layoutTopInset)
        zoomBadgeView.isHidden = false
    }

    func apply(snapshot: DebugOverlayHUDSnapshot?) {
        hudSnapshotStore.publish(snapshot)
        flushPendingHUDSnapshot()
    }

    func apply(settings: ImmersiveMapSettings) {
        currentSettings = settings
        // The first settings the map starts with come straight from the
        // app, before any drag.
        if appGroundFog == nil, settingsOverride.groundFog == nil {
            appGroundFog = settings.scene.groundFog
        }
        // Hidden with the map's controls (`ControlsSettings.isHidden`), the
        // panel keeps what was dragged in it and only stops showing and
        // reading the frames.
        let showsPanel = settings.debug.enableDebugPanel && settings.controls.isHidden == false
        hudView.apply(isDebugPanelEnabled: showsPanel,
                      controls: controls.snapshot())
        showsZoomBadge = showsPanel && settings.debug.showsZoomBadge
        applyZoomBadge(appliedHUDSnapshot)
        #if os(macOS)
        hudView.apply(shadowSettings: settings.scene.shadows,
                      sunDirection: settings.scene.light.direction)
        hudView.apply(fogSettings: settings.scene.fog)
        hudView.apply(atmosphereSettings: settings.scene.atmosphere)
        hudView.apply(groundFogSettings: settings.scene.groundFog, horizonColor: settings.scene.fog.horizonColor)
        if settings.debug.enableDebugPanel == false {
            // The panel's reach goes with the panel, like its other values.
            controls.setLocalLabelMaximumDistanceMeters(nil)
            controls.setLabelPerspectiveMinimumScale(nil)
            controls.setHillshadeFadeCameraDistances(nil)
            controls.setReliefCastsShadows(nil)
        }
        hudView.apply(reliefCastsShadows: controls.reliefCastsShadows() ?? settings.tiles.groundRelief.castsShadows)
        let hillshade = settings.mapStyle.vectorTileStyle.hillshade
        hudView.apply(hillshadeFade: controls.hillshadeFadeCameraDistances()
            ?? hillshade.fadeStartCameraDistances ... max(hillshade.fadeStartCameraDistances, hillshade.fadeEndCameraDistances))
        hudView.apply(labelMinimumScale: controls.labelPerspectiveMinimum()
            ?? settings.labels.base.perspectiveMinimumScale)
        hudView.apply(localLabelDistanceMeters: controls.localLabelMaximumDistance()
            ?? settings.labels.base.localDetailMaximumDistanceMeters)
        #endif
        hudView.apply(tileTraceSnapshot: tileTraceRecorder.snapshot())
        hudView.apply(baseLabelTraceSnapshot: baseLabelTraceRecorder.snapshot())
        if showsPanel {
            startHUDSnapshotTimer()
            flushPendingHUDSnapshot()
        } else {
            stopHUDSnapshotTimer()
            consumedHUDSnapshotVersion = hudSnapshotStore.publish(nil)
            appliedHUDSnapshot = nil
            hudView.apply(snapshot: nil)
            applyZoomBadge(nil)
        }
    }

    /// The one thing neither a frame nor the loader announces: a stage
    /// growing old (`TileLoadingStatusTileSnapshot.stageAgeSeconds`), in
    /// whole seconds.
    private static let stageAgeTimerInterval: TimeInterval = 1

    private func startHUDSnapshotTimer() {
        guard hudSnapshotTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: Self.stageAgeTimerInterval,
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

    /// Applies the newest frame snapshot, in the frame's own turn of the
    /// main thread (`DebugOverlayHUDSnapshotStore.onSnapshotPublished`),
    /// or, when there is none, the tile list read again from the reporter:
    /// the loader moves between frames too, says so through the store, and
    /// the rows follow it at once instead of waiting for a frame the
    /// sleeping loop will not render.
    private func flushPendingHUDSnapshot() {
        if let value = hudSnapshotStore.consumeLatest(after: consumedHUDSnapshotVersion) {
            consumedHUDSnapshotVersion = value.version
            appliedHUDSnapshot = value.snapshot
            hudView.apply(snapshot: value.snapshot)
            applyZoomBadge(value.snapshot)
            return
        }
        refreshTileLoadingStatusBetweenFrames()
    }

    private func refreshTileLoadingStatusBetweenFrames() {
        guard let refreshed = hudSnapshotStore.refreshedSnapshot(applying: appliedHUDSnapshot) else {
            return
        }
        appliedHUDSnapshot = refreshed
        hudView.apply(snapshot: refreshed)
    }
}

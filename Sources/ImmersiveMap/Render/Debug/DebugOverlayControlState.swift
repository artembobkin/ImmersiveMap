// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct DebugOverlayControlSnapshot: Equatable {
    let axesEnabled: Bool
    let tileLayersEnabled: Bool
    let wireframeEnabled: Bool
    let roadLabelTilesEnabled: Bool
    let baseLabelBoundsEnabled: Bool
    let roadLabelBoundsEnabled: Bool
    let tileGridEnabled: Bool
    let tileGridDensity: Int
    /// The ring rules by target zoom (`RingRuleSets`), normalized.
    let ringRuleSets: RingRuleSets
    /// The labels' reach by camera zoom (`LabelDistanceRules`), normalized.
    let labelDistanceRules: LabelDistanceRules
    /// The local detail's distance the panel has been dragged to, in
    /// metres; nil keeps `BaseSettings.localDetailMaximumDistanceMeters`.
    let localLabelMaximumDistanceMeters: Float?
    /// The labels' shrink floor the panel has been dragged to; nil keeps
    /// `BaseSettings.perspectiveMinimumScale`.
    let labelPerspectiveMinimumScale: Float?

    init(axesEnabled: Bool,
         tileLayersEnabled: Bool,
         wireframeEnabled: Bool,
         roadLabelTilesEnabled: Bool = false,
         baseLabelBoundsEnabled: Bool = false,
         roadLabelBoundsEnabled: Bool = false,
         tileGridEnabled: Bool = false,
         tileGridDensity: Int = DebugTileGridDensity.standard,
         ringRuleSets: RingRuleSets = .default,
         labelDistanceRules: LabelDistanceRules = .default,
         localLabelMaximumDistanceMeters: Float? = nil,
         labelPerspectiveMinimumScale: Float? = nil) {
        self.axesEnabled = axesEnabled
        self.tileLayersEnabled = tileLayersEnabled
        self.wireframeEnabled = wireframeEnabled
        self.roadLabelTilesEnabled = roadLabelTilesEnabled
        self.baseLabelBoundsEnabled = baseLabelBoundsEnabled
        self.roadLabelBoundsEnabled = roadLabelBoundsEnabled
        self.tileGridEnabled = tileGridEnabled
        self.tileGridDensity = DebugTileGridDensity.clamp(tileGridDensity)
        self.ringRuleSets = ringRuleSets.normalized()
        self.labelDistanceRules = labelDistanceRules.normalized()
        self.localLabelMaximumDistanceMeters = localLabelMaximumDistanceMeters
        self.labelPerspectiveMinimumScale = labelPerspectiveMinimumScale
    }
}

final class DebugOverlayControlState {
    private let lock = NSLock()
    private var axesEnabled = false
    private var tileLayersEnabled = false
    private var wireframeEnabled = false
    private var roadLabelTilesEnabled = false
    private var baseLabelBoundsEnabled = false
    private var roadLabelBoundsEnabled = false
    private var tileGridEnabled = false
    private var tileGridDensity = DebugTileGridDensity.standard
    private var ringRuleSets = RingRuleSets.default
    private var labelDistanceRules = LabelDistanceRules.default
    private var localLabelMaximumDistanceMeters: Float?
    private var labelPerspectiveMinimumScale: Float?

    /// The controls as a frame reads them.
    func snapshot() -> DebugOverlayControlSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DebugOverlayControlSnapshot(axesEnabled: axesEnabled,
                                           tileLayersEnabled: tileLayersEnabled,
                                           wireframeEnabled: wireframeEnabled,
                                           roadLabelTilesEnabled: roadLabelTilesEnabled,
                                           baseLabelBoundsEnabled: baseLabelBoundsEnabled,
                                           roadLabelBoundsEnabled: roadLabelBoundsEnabled,
                                           tileGridEnabled: tileGridEnabled,
                                           tileGridDensity: tileGridDensity,
                                           ringRuleSets: ringRuleSets,
                                           labelDistanceRules: labelDistanceRules,
                                           localLabelMaximumDistanceMeters: localLabelMaximumDistanceMeters,
                                           labelPerspectiveMinimumScale: labelPerspectiveMinimumScale)
    }

    /// The local detail's distance in metres, nil for the setting's.
    func localLabelMaximumDistance() -> Float? {
        lock.lock()
        defer { lock.unlock() }
        return localLabelMaximumDistanceMeters
    }

    /// The labels' shrink floor, nil for the setting's.
    func labelPerspectiveMinimum() -> Float? {
        lock.lock()
        defer { lock.unlock() }
        return labelPerspectiveMinimumScale
    }

    /// The labels' reach at a camera zoom, from the rule the zoom falls
    /// in (`LabelDistanceRules`).
    func labelDistanceScale(forCameraZoom cameraZoom: Double) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return labelDistanceRules.scale(forCameraZoom: cameraZoom)
    }

    func setLabelPerspectiveMinimumScale(_ scale: Float?) {
        lock.lock()
        labelPerspectiveMinimumScale = scale.map { min(max($0, 0), 1) }
        lock.unlock()
    }

    func setLocalLabelMaximumDistanceMeters(_ meters: Float?) {
        lock.lock()
        localLabelMaximumDistanceMeters = meters.map { max(0, $0) }
        lock.unlock()
    }


    func setAxesEnabled(_ isEnabled: Bool) {
        lock.lock()
        axesEnabled = isEnabled
        lock.unlock()
    }

    func setTileLayersEnabled(_ isEnabled: Bool) {
        lock.lock()
        tileLayersEnabled = isEnabled
        lock.unlock()
    }

    func setWireframeEnabled(_ isEnabled: Bool) {
        lock.lock()
        wireframeEnabled = isEnabled
        lock.unlock()
    }

    func setRoadLabelTilesEnabled(_ isEnabled: Bool) {
        lock.lock()
        roadLabelTilesEnabled = isEnabled
        lock.unlock()
    }

    func setBaseLabelBoundsEnabled(_ isEnabled: Bool) {
        lock.lock()
        baseLabelBoundsEnabled = isEnabled
        lock.unlock()
    }

    func setRoadLabelBoundsEnabled(_ isEnabled: Bool) {
        lock.lock()
        roadLabelBoundsEnabled = isEnabled
        lock.unlock()
    }

    func setTileGridEnabled(_ isEnabled: Bool) {
        lock.lock()
        tileGridEnabled = isEnabled
        lock.unlock()
    }

    func setTileGridDensity(_ density: Int) {
        lock.lock()
        tileGridDensity = DebugTileGridDensity.clamp(density)
        lock.unlock()
    }

    func setRingRuleSets(_ sets: RingRuleSets) {
        lock.lock()
        ringRuleSets = sets.normalized()
        lock.unlock()
    }

    func setLabelDistanceRules(_ rules: LabelDistanceRules) {
        lock.lock()
        labelDistanceRules = rules.normalized()
        lock.unlock()
    }
}

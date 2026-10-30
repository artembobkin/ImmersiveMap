// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

package struct DebugOverlayControlSnapshot: Equatable {
    package let axesEnabled: Bool
    package let tileLayersEnabled: Bool
    package let wireframeEnabled: Bool
    package let roadLabelTilesEnabled: Bool
    package let baseLabelBoundsEnabled: Bool
    package let roadLabelBoundsEnabled: Bool
    package let tileGridEnabled: Bool
    package let tileGridDensity: Int
    /// The ring rules by target zoom (`RingRuleSets`), normalized.
    package let ringRuleSets: RingRuleSets
    /// The labels' reach by camera zoom (`LabelDistanceRules`), normalized.
    package let labelDistanceRules: LabelDistanceRules
    /// The local detail's distance the panel has been dragged to, in
    /// metres; nil keeps `BaseSettings.localDetailMaximumDistanceMeters`.
    package let localLabelMaximumDistanceMeters: Float?
    /// The labels' shrink floor the panel has been dragged to; nil keeps
    /// `BaseSettings.perspectiveMinimumScale`.
    package let labelPerspectiveMinimumScale: Float?

    package init(axesEnabled: Bool,
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

package final class DebugOverlayControlState {
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
    private var draggedHillshadeFade: GroundReliefHillshade.Fade?
    private var draggedHillshadeAmounts: GroundReliefHillshade.Amounts?
    private var reliefShadows: Bool?
    private var draggedTerrainOcclusion: ImmersiveMapTerrainOcclusion?
    private var occlusionDebugView = false

    /// The controls as a frame reads them.
    package func snapshot() -> DebugOverlayControlSnapshot {
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
    package func localLabelMaximumDistance() -> Float? {
        lock.lock()
        defer { lock.unlock() }
        return localLabelMaximumDistanceMeters
    }

    /// The labels' shrink floor, nil for the setting's.
    package func labelPerspectiveMinimum() -> Float? {
        lock.lock()
        defer { lock.unlock() }
        return labelPerspectiveMinimumScale
    }

    /// The labels' reach at a camera zoom, from the rule the zoom falls
    /// in (`LabelDistanceRules`).
    package func labelDistanceScale(forCameraZoom cameraZoom: Double) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return labelDistanceRules.scale(forCameraZoom: cameraZoom)
    }

    /// The hillshade's fade the panel has been dragged to, metres from
    /// the eye by the zoom, nil for the style's
    /// (`ImmersiveMapHillshade.fadeStartMeters`, `fadeEndMeters`).
    package func hillshadeFade() -> GroundReliefHillshade.Fade? {
        lock.lock()
        defer { lock.unlock() }
        return draggedHillshadeFade
    }

    /// The hillshade's amounts the panel has been dragged to, nil for
    /// the style's (`ImmersiveMapHillshade.intensity`, the alphas of
    /// `shadowColor` and `highlightColor`).
    package func hillshadeAmounts() -> GroundReliefHillshade.Amounts? {
        lock.lock()
        defer { lock.unlock() }
        return draggedHillshadeAmounts
    }

    package func setHillshadeAmounts(_ amounts: GroundReliefHillshade.Amounts?) {
        lock.lock()
        draggedHillshadeAmounts = amounts
        lock.unlock()
    }

    /// The occlusion of the sky the panel has been dragged to, nil for
    /// the style's (`ImmersiveMapTerrainOcclusion`).
    package func terrainOcclusion() -> ImmersiveMapTerrainOcclusion? {
        lock.lock()
        defer { lock.unlock() }
        return draggedTerrainOcclusion
    }

    package func setTerrainOcclusion(_ occlusion: ImmersiveMapTerrainOcclusion?) {
        lock.lock()
        draggedTerrainOcclusion = occlusion
        lock.unlock()
    }

    /// Whether the frame draws the occlusion of the sky alone, in grey,
    /// the panel's view of it.
    package func terrainOcclusionDebugView() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return occlusionDebugView
    }

    package func setTerrainOcclusionDebugView(_ isEnabled: Bool) {
        lock.lock()
        occlusionDebugView = isEnabled
        lock.unlock()
    }

    /// Whether the mountains cast their shadows as the panel set it, nil
    /// for the setting's (`GroundReliefSettings.castsShadows`).
    package func reliefCastsShadows() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return reliefShadows
    }

    package func setReliefCastsShadows(_ isEnabled: Bool?) {
        lock.lock()
        reliefShadows = isEnabled
        lock.unlock()
    }

    package func setHillshadeFade(_ fade: GroundReliefHillshade.Fade?) {
        lock.lock()
        draggedHillshadeFade = fade
        lock.unlock()
    }

    package func setLabelPerspectiveMinimumScale(_ scale: Float?) {
        lock.lock()
        labelPerspectiveMinimumScale = scale.map { min(max($0, 0), 1) }
        lock.unlock()
    }

    package func setLocalLabelMaximumDistanceMeters(_ meters: Float?) {
        lock.lock()
        localLabelMaximumDistanceMeters = meters.map { max(0, $0) }
        lock.unlock()
    }


    package func setAxesEnabled(_ isEnabled: Bool) {
        lock.lock()
        axesEnabled = isEnabled
        lock.unlock()
    }

    package func setTileLayersEnabled(_ isEnabled: Bool) {
        lock.lock()
        tileLayersEnabled = isEnabled
        lock.unlock()
    }

    package func setWireframeEnabled(_ isEnabled: Bool) {
        lock.lock()
        wireframeEnabled = isEnabled
        lock.unlock()
    }

    package func setRoadLabelTilesEnabled(_ isEnabled: Bool) {
        lock.lock()
        roadLabelTilesEnabled = isEnabled
        lock.unlock()
    }

    package func setBaseLabelBoundsEnabled(_ isEnabled: Bool) {
        lock.lock()
        baseLabelBoundsEnabled = isEnabled
        lock.unlock()
    }

    package func setRoadLabelBoundsEnabled(_ isEnabled: Bool) {
        lock.lock()
        roadLabelBoundsEnabled = isEnabled
        lock.unlock()
    }

    package func setTileGridEnabled(_ isEnabled: Bool) {
        lock.lock()
        tileGridEnabled = isEnabled
        lock.unlock()
    }

    package func setTileGridDensity(_ density: Int) {
        lock.lock()
        tileGridDensity = DebugTileGridDensity.clamp(density)
        lock.unlock()
    }

    package func setRingRuleSets(_ sets: RingRuleSets) {
        lock.lock()
        ringRuleSets = sets.normalized()
        lock.unlock()
    }

    package func setLabelDistanceRules(_ rules: LabelDistanceRules) {
        lock.lock()
        labelDistanceRules = rules.normalized()
        lock.unlock()
    }
}

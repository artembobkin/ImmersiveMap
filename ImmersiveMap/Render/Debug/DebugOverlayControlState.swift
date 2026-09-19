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
    /// The plane's depth rules (`FlatDepthRuleCoverage`), normalized.
    let flatDepthRules: FlatDepthRules
    /// The buildings' screen-footprint level of detail (`BuildingLODUniform`):
    /// a building whose footprint is under the cut is dropped, one under
    /// the fade sinks into its footprint.
    let buildingLODCutPixels: Float
    let buildingLODFadePixels: Float

    init(axesEnabled: Bool,
         tileLayersEnabled: Bool,
         wireframeEnabled: Bool,
         roadLabelTilesEnabled: Bool = false,
         baseLabelBoundsEnabled: Bool = false,
         roadLabelBoundsEnabled: Bool = false,
         tileGridEnabled: Bool = false,
         tileGridDensity: Int = DebugTileGridDensity.standard,
         flatDepthRules: FlatDepthRules = .default,
         buildingLODCutPixels: Float = BuildingLODUniform.defaultCutPixels,
         buildingLODFadePixels: Float = BuildingLODUniform.defaultFadePixels) {
        self.buildingLODCutPixels = max(buildingLODCutPixels, 0)
        self.buildingLODFadePixels = max(buildingLODFadePixels, self.buildingLODCutPixels)
        self.axesEnabled = axesEnabled
        self.tileLayersEnabled = tileLayersEnabled
        self.wireframeEnabled = wireframeEnabled
        self.roadLabelTilesEnabled = roadLabelTilesEnabled
        self.baseLabelBoundsEnabled = baseLabelBoundsEnabled
        self.roadLabelBoundsEnabled = roadLabelBoundsEnabled
        self.tileGridEnabled = tileGridEnabled
        self.tileGridDensity = DebugTileGridDensity.clamp(tileGridDensity)
        self.flatDepthRules = flatDepthRules.normalized()
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
    private var flatDepthRules = FlatDepthRules.default
    private var buildingLODCutPixels = BuildingLODUniform.defaultCutPixels
    private var buildingLODFadePixels = BuildingLODUniform.defaultFadePixels

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
                                           flatDepthRules: flatDepthRules,
                                           buildingLODCutPixels: buildingLODCutPixels,
                                           buildingLODFadePixels: buildingLODFadePixels)
    }

    func setBuildingLOD(cutPixels: Float, fadePixels: Float) {
        lock.lock()
        buildingLODCutPixels = cutPixels
        buildingLODFadePixels = fadePixels
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

    func setFlatDepthRules(_ rules: FlatDepthRules) {
        lock.lock()
        flatDepthRules = rules.normalized()
        lock.unlock()
    }
}

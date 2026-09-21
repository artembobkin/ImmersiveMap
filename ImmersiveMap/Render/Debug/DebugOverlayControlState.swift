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
    /// The tuning of the rule set the snapshot was taken for
    /// (`RingRuleSetTuning`, `DebugOverlayControlState.snapshot(forTargetZoom:)`).
    /// The flat building fills' footprint fade (`BuildingFootprintFade`), as
    /// footprint areas on screen in square pixels: a fill is gone at the
    /// first and under, whole at the second and over.
    let buildingGoneAreaPixels: Float
    let buildingOpaqueAreaPixels: Float
    /// The roads' thinness fade (`RoadThinnessFade`).
    let roadThinnessFade: RoadThinnessFade
    /// Where the flat ground turns from geometry into pictures and what the
    /// pictures hold (`RasterZone`).
    let rasterZone: RasterZone

    init(axesEnabled: Bool,
         tileLayersEnabled: Bool,
         wireframeEnabled: Bool,
         roadLabelTilesEnabled: Bool = false,
         baseLabelBoundsEnabled: Bool = false,
         roadLabelBoundsEnabled: Bool = false,
         tileGridEnabled: Bool = false,
         tileGridDensity: Int = DebugTileGridDensity.standard,
         ringRuleSets: RingRuleSets = .default,
         buildingGoneAreaPixels: Float = BuildingFootprintFade.defaultGoneAreaPixels,
         buildingOpaqueAreaPixels: Float = BuildingFootprintFade.defaultOpaqueAreaPixels,
         roadThinnessFade: RoadThinnessFade = .default,
         rasterZone: RasterZone = .default) {
        self.roadThinnessFade = roadThinnessFade
        self.rasterZone = rasterZone
        self.buildingGoneAreaPixels = max(buildingGoneAreaPixels, 0)
        self.buildingOpaqueAreaPixels = max(buildingOpaqueAreaPixels, self.buildingGoneAreaPixels)
        self.axesEnabled = axesEnabled
        self.tileLayersEnabled = tileLayersEnabled
        self.wireframeEnabled = wireframeEnabled
        self.roadLabelTilesEnabled = roadLabelTilesEnabled
        self.baseLabelBoundsEnabled = baseLabelBoundsEnabled
        self.roadLabelBoundsEnabled = roadLabelBoundsEnabled
        self.tileGridEnabled = tileGridEnabled
        self.tileGridDensity = DebugTileGridDensity.clamp(tileGridDensity)
        self.ringRuleSets = ringRuleSets.normalized()
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

    /// The controls as a frame at `targetZoom` reads them: the building
    /// level of detail, the road fade and the raster zone are those of the
    /// rule set the zoom falls in.
    func snapshot(forTargetZoom targetZoom: Int = 0) -> DebugOverlayControlSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let tuning = ringRuleSets.tuning(forTargetZoom: targetZoom)
        return DebugOverlayControlSnapshot(axesEnabled: axesEnabled,
                                           tileLayersEnabled: tileLayersEnabled,
                                           wireframeEnabled: wireframeEnabled,
                                           roadLabelTilesEnabled: roadLabelTilesEnabled,
                                           baseLabelBoundsEnabled: baseLabelBoundsEnabled,
                                           roadLabelBoundsEnabled: roadLabelBoundsEnabled,
                                           tileGridEnabled: tileGridEnabled,
                                           tileGridDensity: tileGridDensity,
                                           ringRuleSets: ringRuleSets,
                                           buildingGoneAreaPixels: tuning.buildingGoneAreaPixels,
                                           buildingOpaqueAreaPixels: tuning.buildingOpaqueAreaPixels,
                                           roadThinnessFade: tuning.roadThinnessFade,
                                           rasterZone: tuning.rasterZone)
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
}

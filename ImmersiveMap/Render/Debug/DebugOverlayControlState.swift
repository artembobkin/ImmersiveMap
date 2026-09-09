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
    /// The road distance LOD's fade ring about the look-at point, in camera
    /// distances (RoadDistanceLOD); bench knobs for the flat surface drawer.
    let roadFadeStartCameraDistances: Float
    let roadFadeEndCameraDistances: Float
    /// The floor of the ring's outer radius on the ground, in metres.
    let roadFadeMinimumEndMeters: Float
    /// The flat coverage's reach about the eye, in camera distances
    /// (FlatDistanceCoverage.farRadius): ground beyond it gets no tile.
    let coverageFarRadiusCameraDistances: Float

    init(axesEnabled: Bool,
         tileLayersEnabled: Bool,
         wireframeEnabled: Bool,
         roadLabelTilesEnabled: Bool = false,
         baseLabelBoundsEnabled: Bool = false,
         roadLabelBoundsEnabled: Bool = false,
         tileGridEnabled: Bool = false,
         tileGridDensity: Int = DebugTileGridDensity.standard,
         roadFadeStartCameraDistances: Float = RoadDistanceLOD.fadeStartCameraDistances,
         roadFadeEndCameraDistances: Float = RoadDistanceLOD.fadeEndCameraDistances,
         roadFadeMinimumEndMeters: Float = RoadDistanceLOD.minimumFadeEndMeters,
         coverageFarRadiusCameraDistances: Float = Float(FlatDistanceCoverage.farRadius)) {
        self.axesEnabled = axesEnabled
        self.tileLayersEnabled = tileLayersEnabled
        self.wireframeEnabled = wireframeEnabled
        self.roadLabelTilesEnabled = roadLabelTilesEnabled
        self.baseLabelBoundsEnabled = baseLabelBoundsEnabled
        self.roadLabelBoundsEnabled = roadLabelBoundsEnabled
        self.tileGridEnabled = tileGridEnabled
        self.tileGridDensity = DebugTileGridDensity.clamp(tileGridDensity)
        let start = RoadDistanceLOD.clampCameraDistances(roadFadeStartCameraDistances,
                                                         fallback: RoadDistanceLOD.fadeStartCameraDistances)
        self.roadFadeStartCameraDistances = start
        self.roadFadeEndCameraDistances = max(start, RoadDistanceLOD.clampCameraDistances(roadFadeEndCameraDistances,
                                                                                          fallback: RoadDistanceLOD.fadeEndCameraDistances))
        self.roadFadeMinimumEndMeters = RoadDistanceLOD.clampMinimumFadeEndMeters(roadFadeMinimumEndMeters)
        self.coverageFarRadiusCameraDistances = Float(FlatDistanceCoverage.clampFarRadius(Double(coverageFarRadiusCameraDistances)))
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
    private var roadFadeStartCameraDistances = RoadDistanceLOD.fadeStartCameraDistances
    private var roadFadeEndCameraDistances = RoadDistanceLOD.fadeEndCameraDistances
    private var roadFadeMinimumEndMeters = RoadDistanceLOD.minimumFadeEndMeters
    private var coverageFarRadiusCameraDistances = Float(FlatDistanceCoverage.farRadius)

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
                                           roadFadeStartCameraDistances: roadFadeStartCameraDistances,
                                           roadFadeEndCameraDistances: roadFadeEndCameraDistances,
                                           roadFadeMinimumEndMeters: roadFadeMinimumEndMeters,
                                           coverageFarRadiusCameraDistances: coverageFarRadiusCameraDistances)
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

    /// The knobs are stored as set; the snapshot orders the band (the end
    /// never below the start).
    func setRoadFadeStartCameraDistances(_ cameraDistances: Float) {
        lock.lock()
        roadFadeStartCameraDistances = RoadDistanceLOD.clampCameraDistances(cameraDistances,
                                                                            fallback: RoadDistanceLOD.fadeStartCameraDistances)
        lock.unlock()
    }

    func setRoadFadeEndCameraDistances(_ cameraDistances: Float) {
        lock.lock()
        roadFadeEndCameraDistances = RoadDistanceLOD.clampCameraDistances(cameraDistances,
                                                                          fallback: RoadDistanceLOD.fadeEndCameraDistances)
        lock.unlock()
    }

    func setRoadFadeMinimumEndMeters(_ meters: Float) {
        lock.lock()
        roadFadeMinimumEndMeters = RoadDistanceLOD.clampMinimumFadeEndMeters(meters)
        lock.unlock()
    }

    func setCoverageFarRadiusCameraDistances(_ cameraDistances: Float) {
        lock.lock()
        coverageFarRadiusCameraDistances = Float(FlatDistanceCoverage.clampFarRadius(Double(cameraDistances)))
        lock.unlock()
    }
}

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

    init(axesEnabled: Bool,
         tileLayersEnabled: Bool,
         wireframeEnabled: Bool,
         roadLabelTilesEnabled: Bool = false,
         baseLabelBoundsEnabled: Bool = false,
         roadLabelBoundsEnabled: Bool = false) {
        self.axesEnabled = axesEnabled
        self.tileLayersEnabled = tileLayersEnabled
        self.wireframeEnabled = wireframeEnabled
        self.roadLabelTilesEnabled = roadLabelTilesEnabled
        self.baseLabelBoundsEnabled = baseLabelBoundsEnabled
        self.roadLabelBoundsEnabled = roadLabelBoundsEnabled
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

    func snapshot() -> DebugOverlayControlSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DebugOverlayControlSnapshot(axesEnabled: axesEnabled,
                                           tileLayersEnabled: tileLayersEnabled,
                                           wireframeEnabled: wireframeEnabled,
                                           roadLabelTilesEnabled: roadLabelTilesEnabled,
                                           baseLabelBoundsEnabled: baseLabelBoundsEnabled,
                                           roadLabelBoundsEnabled: roadLabelBoundsEnabled)
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
}

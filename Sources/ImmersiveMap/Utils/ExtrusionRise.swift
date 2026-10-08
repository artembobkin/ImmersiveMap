// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// How far the parts of a layer of standing things (the extruded buildings
/// by the cell of the map they stand in, the models by their tile) have
/// risen out of the ground: 0 not drawn, 1 at full height. A part rises
/// over `seconds` from the frame it is first drawn in: when the camera
/// reaches the layer's zoom, and when its tile arrives later, while the
/// camera is already there. It is forgotten once a frame leaves it out, so
/// it rises again on its return. Leaving the zoom, the whole layer is gone
/// at once. The extruded buildings grow by `heightScale`, the models come
/// up out of the ground by it whole, and the shadows and the labels on the
/// roofs rise with them.
struct ExtrusionRise<Key: Hashable> {
    private var startTimes: [Key: TimeInterval] = [:]
    private var lastTime: TimeInterval?
    private var seconds: TimeInterval = 0

    /// Whether a part is still rising and the frames have to keep coming.
    private(set) var isAnimating = false

    /// Starts the parts first drawn in this frame, forgets the ones it
    /// leaves out. `keys` are the parts the frame draws, empty when the
    /// camera is off the layer's zoom. The first frame stands its parts up
    /// at once: a map opened at a street zoom shows its buildings
    /// standing. `seconds` of zero stands every part up at once.
    mutating func advance<Keys: Sequence>(keys: Keys, time: TimeInterval, seconds: TimeInterval) where Keys.Element == Key {
        let isFirstFrame = lastTime == nil
        lastTime = time
        self.seconds = seconds
        var drawn: [Key: TimeInterval] = [:]
        for key in keys where drawn[key] == nil {
            drawn[key] = startTimes[key] ?? (isFirstFrame ? -.infinity : time)
        }
        startTimes = drawn
        isAnimating = seconds > 0 && drawn.values.contains { time - $0 < seconds }
    }

    /// 0 to 1, linear in time. 0 for a part the frame does not draw.
    func progress(of key: Key, time: TimeInterval) -> Float {
        guard let start = startTimes[key] else { return 0 }
        guard seconds > 0 else { return 1 }
        return Float(min(max((time - start) / seconds, 0), 1))
    }

    /// The progress eased out: quick from the ground, settling at the top.
    /// 0 for a part the frame does not draw.
    func heightScale(of key: Key, time: TimeInterval) -> Float {
        guard startTimes[key] != nil else { return 0 }
        let remaining = 1 - progress(of: key, time: time)
        return 1 - remaining * remaining * remaining
    }

    mutating func reset() {
        self = ExtrusionRise()
    }
}

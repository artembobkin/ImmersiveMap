// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Hysteresis for releasing globe atlas pages. The pages (86 MiB each at
/// 4096 px with mips) are needed only by spherical mode, but freeing them right
/// at the globe/flat boundary is not an option: zoom oscillation around the
/// transition threshold would recreate hundreds of MiB of textures every few
/// frames. Pages are released after a sustained stay in flat; returning to the
/// globe costs one repaint of the pages against the current atlas plan.
struct TileAtlasPageRetention {
    /// Seconds of flat rendering after which the atlas pages are released.
    static let releaseDelay: TimeInterval = 5

    private var lastSphericalTime: TimeInterval?

    /// Called once per frame. Returns true exactly once, when the pages are due
    /// for release: the map has been flat longer than `releaseDelay` and the
    /// pages are still alive.
    mutating func shouldReleasePages(isSpherical: Bool,
                                     hasPages: Bool,
                                     time: TimeInterval) -> Bool {
        if isSpherical {
            lastSphericalTime = time
            return false
        }
        guard hasPages else {
            lastSphericalTime = nil
            return false
        }
        guard let lastSphericalTime else {
            // Pages exist but no spherical frame has been seen yet: start counting
            // from the current frame to avoid releasing based on an "infinitely
            // old" globe.
            self.lastSphericalTime = time
            return false
        }
        if time - lastSphericalTime >= Self.releaseDelay {
            self.lastSphericalTime = nil
            return true
        }
        return false
    }
}

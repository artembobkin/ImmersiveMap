// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import os

/// Process-wide signposters for Instruments profiling. Signpost intervals cost
/// nearly nothing while no instrument is recording, so they stay enabled in
/// release builds. `render` lines the frame stages and pass encoding up with
/// the GPU track in Metal System Trace; `tiles` exposes the download and
/// parse pipeline, whose intervals overlap and therefore carry per-call
/// signpost IDs.
enum MapSignposts {
    static let render = OSSignposter(subsystem: "ImmersiveMap", category: "Render")
    static let tiles = OSSignposter(subsystem: "ImmersiveMap", category: "Tiles")
}

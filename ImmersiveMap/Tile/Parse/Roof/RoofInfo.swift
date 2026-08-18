// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// OSM `roof:orientation`: whether the ridge runs along or across the long
/// axis of the footprint. `along` is the OSM default and the builder's too.
enum RoofOrientation {
    case along
    case across
}

struct RoofInfo {
    let height: Float
    let shape: RoofShape
    /// From `roof:orientation`; nil when the tag is absent.
    let orientation: RoofOrientation?
    /// From `roof:direction`, a compass azimuth in degrees: the downslope
    /// direction the roof faces. nil when the tag is absent.
    let directionDegrees: Float?
}

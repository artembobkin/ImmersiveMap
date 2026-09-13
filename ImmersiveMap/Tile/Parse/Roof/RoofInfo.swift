// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// A building's roof as the mesh builder needs it: the style's reading
/// (`ImmersiveMapRoof`) with the height converted to this tile's units.
struct RoofInfo {
    let height: Float
    let shape: ImmersiveMapRoofShape
    /// From the style's reading; nil takes the OpenStreetMap default, along.
    let orientation: ImmersiveMapRoofOrientation?
    /// A compass azimuth in degrees: the downslope direction the roof faces.
    /// nil leaves the direction to the footprint.
    let directionDegrees: Float?
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// An OpenStreetMap element: how an app names a feature of the map
/// independently of the tiles, for example the building a landmark model
/// replaces (`.relation(3334755)` is the Bolshoi Theatre). Which tile
/// feature that is, the schema answers (`ImmersiveMapTileSchema.tileFeatureID(of:)`).
public enum ImmersiveMapOSMElement: Hashable, Sendable {
    case node(UInt64)
    case way(UInt64)
    case relation(UInt64)
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The sprites the engine can draw beside a point label. Which one a
/// feature takes is the style's decision (`PointLabelStyle.icon`); how
/// each is drawn is the engine's sprite atlas.
public enum PoiSpriteIcon: String, CaseIterable, Sendable {
    case restaurant
    case cafe
    case bar
    case park
    case museum
    case hospital
    case school
    case airport
    case stadium
    case hotel
    case shopping
    case gasStation
    case pharmacy
    case viewpoint
}

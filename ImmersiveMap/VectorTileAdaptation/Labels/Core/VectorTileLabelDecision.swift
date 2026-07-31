// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Label category for the distance detail tiers: anchor labels
/// (places, water, peaks) live in all tiers, POIs degrade to an icon
/// in the middle tier and disappear in the far one, house numbers live only in the near tier.
enum VectorTileLabelDetailCategory: UInt8 {
    case anchor
    case poi
    case housenumber
}

struct VectorTileLabelDecision {
    let text: String
    let identity: VectorTileLabelIdentity
    let priority: VectorTileLabelPriority
    let placement: VectorTileLabelPlacementIntent
    let style: LabelTextStyle
    let poiIcon: PoiSpriteIcon?
    let detailCategory: VectorTileLabelDetailCategory
}

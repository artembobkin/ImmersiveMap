// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

struct VectorTileLabelDecision {
    let text: String
    let identity: VectorTileLabelIdentity
    let priority: VectorTileLabelPriority
    let placement: VectorTileLabelPlacementIntent
    let style: LabelTextStyle
    let poiIcon: PoiSpriteIcon?
}

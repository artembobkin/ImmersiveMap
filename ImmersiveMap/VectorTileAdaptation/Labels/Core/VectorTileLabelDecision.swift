// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Категория лейбла для дистанционных тиров детализации: якорные подписи
/// (места, вода, пики) живут во всех тирах, заведения деградируют до иконки
/// в среднем тире и исчезают в дальнем, номера домов живут только в ближнем.
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

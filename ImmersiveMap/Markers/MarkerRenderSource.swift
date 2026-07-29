// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Вход проекции одного маркера: внутренний id (назначается UI-runtime,
/// публичные Identifiable-id через слой не ходят) и кешированный базис
/// координаты.
struct MarkerProjectionEntry: Equatable, Sendable {
    let id: UInt64
    let basis: GeoProjectionBasis
}

struct MarkerProjectionInput: Equatable, Sendable {
    static let empty = MarkerProjectionInput(entries: [])

    let entries: [MarkerProjectionEntry]
}

/// Источник координат маркеров для движка кадра. Читается синхронно на
/// main thread внутри кадра: движок однопоточный (display link в main
/// runloop, см. ImmersiveMapRenderDriver).
protocol MarkerRenderSource: AnyObject {
    var currentMarkerProjectionInput: MarkerProjectionInput { get }
}

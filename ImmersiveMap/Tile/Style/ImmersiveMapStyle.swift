// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

protocol ImmersiveMapStyle {
    var preparedTileStyleRevision: UInt32 { get }
    func getMapBaseColors() -> ImmersiveMapBaseColors
    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle
}

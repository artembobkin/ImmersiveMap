// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

extension FeatureStyle {
    /// The tessellated ribbon a point-locked stroke is hosted on, in tile
    /// units per layout point: wide enough that the screen-space edge the
    /// shader resolves never runs past the geometry at the zooms the stroke
    /// is meant for.
    public static let pointLockedRibbonUnitsPerPoint: Double = 12
}

extension LinePass {
    /// A stroke whose width is stated in on-screen points and held there at
    /// every zoom: by default coming in over the first zoom level off the
    /// whole-planet view (camera zoom 0 to 1) and opaque from there, butt
    /// ends, plain joins, the dash pattern in points, and a ribbon
    /// provisioned to host the width.
    public static func pointLocked(key: UInt8,
                                   color: SIMD4<Float>,
                                   widthPoints: Float,
                                   dashLengthPoints: Float = 0,
                                   dashGapPoints: Float = 0,
                                   zoomFade: ImmersiveMapZoomFade = .fadeIn(from: 0, to: 1)) -> LinePass {
        LinePass(key: key,
                 color: color,
                 zoomFade: zoomFade,
                 lineWidthPoints: widthPoints,
                 dashLengthPoints: dashLengthPoints,
                 dashGapPoints: dashGapPoints,
                 lineGeometry: LineGeometryStyle(
                     lineWidth: Double(widthPoints) * FeatureStyle.pointLockedRibbonUnitsPerPoint
                 ))
    }
}

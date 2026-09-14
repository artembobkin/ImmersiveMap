// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// What the parser bakes of a style into a tile's style table: the colours
/// of one stroke or fill and its line parameters, keyed by the style's key.
/// A fill is baked as a stroke of the fill's colours on the standard fill
/// ribbon width; the far colour and the outline flag are a fill's alone.
struct BakedStyle {
    let pass: LinePass
    let farColor: SIMD4<Float>?
    let outlineAntialiasing: Bool

    /// The ribbon width every fill is baked with: the edge threshold it
    /// yields is what the fill shaders have always read.
    static let fillRibbonWidth: Double = 100

    init(pass: LinePass) {
        self.pass = pass
        self.farColor = nil
        self.outlineAntialiasing = false
    }

    init(fill: FillStyle) {
        self.pass = LinePass(key: fill.key,
                             color: fill.color,
                             lowZoomFadeMask: fill.lowZoomFadeMask,
                             lineGeometry: LineGeometryStyle(lineWidth: Self.fillRibbonWidth))
        self.farColor = fill.farColor
        self.outlineAntialiasing = fill.outlineAntialiasing
    }

    init(extrusion: ExtrusionStyle) {
        self.pass = LinePass(key: extrusion.key,
                             color: extrusion.color,
                             lineGeometry: LineGeometryStyle(lineWidth: Self.fillRibbonWidth))
        self.farColor = nil
        self.outlineAntialiasing = false
    }

    var color: SIMD4<Float> { pass.color }
    var lowZoomFadeMask: Float { pass.lowZoomFadeMask }
}

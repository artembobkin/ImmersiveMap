// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The colour of a tile zoom in the debug overlays. The tile outlines and
/// the tile labels on the map and the card titles in the debug panel
/// share it, so a zoom reads the same everywhere, and where two zooms
/// overlap, a near ring's tiles over a far ring's or a stand-in in the
/// slot it fills, the overlap shows as two colours. Neighbouring zooms
/// take hues far apart, a golden-ratio step round the wheel, so z6 and z7
/// never look alike. Bright and saturated, for the black stroke on a dark
/// map.
package enum DebugTileZoomPalette {
    private static let hueStep: Float = 0.618034
    private static let hueOffset: Float = 0.12

    package static func color(forZoom zoom: Int) -> SIMD3<Float> {
        let hue = (Float(max(0, zoom)) * hueStep + hueOffset).truncatingRemainder(dividingBy: 1)
        return rgb(hue: hue, saturation: 0.85, value: 1)
    }

    package static func rgb(hue: Float, saturation: Float, value: Float) -> SIMD3<Float> {
        let sector = hue * 6
        let index = Int(sector.rounded(.down)) % 6
        let fraction = sector - sector.rounded(.down)
        let low = value * (1 - saturation)
        let falling = value * (1 - saturation * fraction)
        let rising = value * (1 - saturation * (1 - fraction))
        switch index {
        case 0: return SIMD3(value, rising, low)
        case 1: return SIMD3(falling, value, low)
        case 2: return SIMD3(low, value, rising)
        case 3: return SIMD3(low, falling, value)
        case 4: return SIMD3(rising, low, value)
        default: return SIMD3(value, low, falling)
        }
    }
}

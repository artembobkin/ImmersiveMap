// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

class ImmersiveMapBaseColors {
    fileprivate let tileBgColor: SIMD4<Float>
    fileprivate let backgroundColor: SIMD4<Double>
    fileprivate let waterColor: SIMD4<Float>
    fileprivate let landCoverColor: SIMD4<Float>
    fileprivate let northPoleColor: SIMD4<Float>
    fileprivate let southPoleColor: SIMD4<Float>
    
    public func getTileBgColor() -> SIMD4<Float> {
        return tileBgColor
    }
    
    public func getBackgroundColor() -> SIMD4<Double> {
        return backgroundColor
    }
    
    public func getWaterColor() -> SIMD4<Float> {
        return waterColor
    }
    
    public func getLandCoverColor() -> SIMD4<Float> {
        return landCoverColor
    }
    
    public func getNorthPoleColor() -> SIMD4<Float> {
        return northPoleColor
    }
    
    public func getSouthPoleColor() -> SIMD4<Float> {
        return southPoleColor
    }
    
    init(settings: ImmersiveMapSettings.StyleSettings.BaseColors = ImmersiveMapSettings.default.style.baseColors) {
        self.tileBgColor = settings.tileBackground
        self.backgroundColor = settings.globeBackground
        self.waterColor = settings.water
        self.landCoverColor = settings.landCover
        // Both poles are ice as far as the tiles go: the Arctic sea ice is
        // painted white right up to the northern rim of the last tile row,
        // and Antarctica is ice all the way. The palette says which ice. The
        // northern cap used to take the palette's water on the assumption of
        // open ocean under it, and showed as a dark disc against the white
        // ice around it, worst with the pole near the limb where the surface
        // darkens. Deriving either from the tile background would only hold
        // for a light style: a dark one paints that background near black
        // and the cap fades from the snow at its rim into a dark hole.
        self.northPoleColor = settings.polarIce
        self.southPoleColor = settings.polarIce
    }
}

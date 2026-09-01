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
        // Constant cap colours straight from the style, no bake: the
        // northern cap is the palette's open ocean, the southern the polar
        // ice sheet. If the tiles paint Arctic sea ice white up to the
        // northern rim, a water-coloured north cap reads as a darker disc
        // inside it; that trade was made deliberately when the baked edge
        // strip was removed, and either pole is one palette constant away.
        self.northPoleColor = settings.water
        self.southPoleColor = settings.polarIce
    }
}

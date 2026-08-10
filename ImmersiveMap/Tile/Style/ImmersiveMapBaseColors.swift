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
        // The Arctic is open ocean at the latitudes the cap has to invent, so the
        // northern pole follows the palette's water.
        self.northPoleColor = self.waterColor
        // Antarctica is ice all the way to the pole, and the palette says which
        // ice. Deriving it from the tile background instead would only hold for
        // a light style: a dark one paints that background near black and the
        // cap fades from the snow at its rim into a dark hole at the pole.
        self.southPoleColor = settings.polarIce
    }
}

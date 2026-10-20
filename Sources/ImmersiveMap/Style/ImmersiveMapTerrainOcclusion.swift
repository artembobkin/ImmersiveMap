// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// How much the ground is darkened where the terrain around it hides the
/// sky, where the relief stands (`TileSettings.GroundReliefSettings`),
/// stated by the style like the hillshade (`ImmersiveMapHillshade`): the
/// floor of a valley sees a strip of sky between the ridges and takes
/// less of its light than a summit or an open slope, which see it all.
/// The occlusion is computed from the terrain tiles themselves, once a
/// tile lands (`GroundReliefOcclusion`): for a grid of points over the
/// tile, how high the terrain rises against the sky in each of
/// `directions` directions out to `radiusMeters`, averaged. In metres on
/// the ground, so it reads the same at every zoom, a valley kilometres
/// wide as dark from afar as from near. Drawn at frame time, never baked
/// into the prepared tiles, so a change needs no re-parse, only the
/// terrain tiles computed again.
public struct ImmersiveMapTerrainOcclusion: Equatable, Sendable {
    /// Whether the ground is darkened. True by default.
    public var isEnabled: Bool
    /// How dark a point the terrain hides the sky from entirely is drawn,
    /// 0 to 1: 0 draws nothing, 1 draws it black. 0.6 by default: a deep
    /// valley reads clearly darker, the colours of the map still show.
    public var strength: Float
    /// How far out the terrain is looked at for what hides the sky, in
    /// metres on the ground. 3000 by default: a valley between ridges a
    /// few kilometres apart is read whole, a hill reads against its own
    /// surroundings. Farther reads wider valleys at more computing per
    /// tile, nearer only the folds.
    public var radiusMeters: Float
    /// How many directions the sky is looked at in, 4 to 32. 8 by
    /// default. More directions smooth the result, at a cost in computing
    /// that grows with them.
    public var directions: Int
    /// How many points a side the occlusion is computed for over a
    /// terrain tile, 16 to 1024. 128 by default: with the terrain tiles of
    /// 512 texels, one point for every four texels, finer than the
    /// relief's grid. Raise it for sharper folds at four times the
    /// computing with each doubling.
    public var resolution: Int

    public init(isEnabled: Bool = true,
                strength: Float = 0.6,
                radiusMeters: Float = 3000,
                directions: Int = 8,
                resolution: Int = 128) {
        self.isEnabled = isEnabled
        self.strength = strength
        self.radiusMeters = radiusMeters
        self.directions = directions
        self.resolution = resolution
    }

    /// No darkening.
    public static let none = ImmersiveMapTerrainOcclusion(isEnabled: false)
}

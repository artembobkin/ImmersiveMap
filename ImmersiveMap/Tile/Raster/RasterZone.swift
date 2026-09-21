// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The families of a tile's ground geometry a picture can hold or leave to
/// the vector draw. The road buckets are in none of them: a road is always
/// drawn as geometry.
struct GroundLayerGroups: OptionSet, Hashable {
    let rawValue: UInt8

    /// The plain fills: land, water, landcover, landuse.
    static let landFills = GroundLayerGroups(rawValue: 1)
    /// The fills under the buildings, the footprint fade band.
    static let buildingFootprints = GroundLayerGroups(rawValue: 2)
    /// The ground's line ribbons: rivers, borders.
    static let groundLines = GroundLayerGroups(rawValue: 4)

    static let all: GroundLayerGroups = [.landFills, .buildingFootprints, .groundLines]
}

extension GroundStyleRun {
    /// The family the run belongs to. A fill's outline follows its fill.
    var group: GroundLayerGroups {
        if isLinesClass {
            return .groundLines
        }
        return LowZoomOverviewFade.isFootprintFadeBand(mask: fadeMask) ? .buildingFootprints : .landFills
    }
}

/// Where the flat ground stops being geometry and becomes pictures, and
/// what the pictures hold.
///
/// The ground nearer the camera than `startCameraDistances` is always
/// vector. Past it a rasterizable tile's picture (`TileRasterizer`) fades
/// in over the tile's vector draw, pixel by pixel, and is the whole ground
/// from `startCameraDistances + transitionCameraDistances` on. The measure
/// is the distance from the camera to the ground point, in camera
/// distances (the distance from the camera to the point it looks at), so
/// the zone follows what is on screen and knows nothing of the tile grid:
/// a tile the edge crosses is drawn both ways and blended.
///
/// A picture is one layer in the middle of its tile's paint order. The
/// groups it holds (`pictureGroups`) draw under it as geometry and show
/// through where it has not faded in, and everything else draws over it as
/// geometry at every distance: the groups left out, and the roads always.
/// The plain fills are in every picture, since a picture is opaque: it is
/// the tile's ground.
struct RasterZone: Hashable {
    var isEnabled: Bool
    var startCameraDistances: Float
    var transitionCameraDistances: Float
    /// The building footprint fills are part of the pictures. Off, they
    /// stay geometry over them.
    var rasterizesBuildingFootprints: Bool
    /// The ground lines (rivers, borders) are part of the pictures. Off,
    /// they stay geometry over them.
    var rasterizesGroundLines: Bool

    static let startRange: ClosedRange<Double> = 0 ... 12
    static let transitionRange: ClosedRange<Double> = 0 ... 6
    static let `default` = RasterZone(isEnabled: true,
                                      startCameraDistances: 1.0,
                                      transitionCameraDistances: 2,
                                      rasterizesBuildingFootprints: true,
                                      rasterizesGroundLines: true)

    init(isEnabled: Bool,
         startCameraDistances: Float,
         transitionCameraDistances: Float,
         rasterizesBuildingFootprints: Bool,
         rasterizesGroundLines: Bool) {
        self.isEnabled = isEnabled
        self.startCameraDistances = min(max(startCameraDistances, Float(Self.startRange.lowerBound)),
                                        Float(Self.startRange.upperBound))
        self.transitionCameraDistances = min(max(transitionCameraDistances, Float(Self.transitionRange.lowerBound)),
                                             Float(Self.transitionRange.upperBound))
        self.rasterizesBuildingFootprints = rasterizesBuildingFootprints
        self.rasterizesGroundLines = rasterizesGroundLines
    }

    /// What a picture holds. A tile of a rule that draws no lines
    /// (`FlatRingRule.drawsLines`) has none in its picture either.
    func pictureGroups(drawsLines: Bool) -> GroundLayerGroups {
        var groups: GroundLayerGroups = .landFills
        if rasterizesBuildingFootprints {
            groups.insert(.buildingFootprints)
        }
        if rasterizesGroundLines, drawsLines {
            groups.insert(.groundLines)
        }
        return groups
    }

    /// The zone in world units for a camera at `eye` looking at the render
    /// world's origin.
    func span(eye: SIMD3<Float>) -> Span {
        let cameraDistance = simd_length(eye)
        let start = startCameraDistances * cameraDistance
        return Span(start: start, end: start + transitionCameraDistances * cameraDistance)
    }

    /// The distances from the camera between which a picture fades in.
    struct Span: Equatable {
        let start: Float
        let end: Float

        /// The picture's share of a ground point at `distance`: the
        /// shader's ramp (TileRaster.metal), a smoothstep.
        func pictureShare(distance: Float) -> Float {
            guard end > start else { return distance >= start ? 1 : 0 }
            let t = min(max((distance - start) / (end - start), 0), 1)
            return t * t * (3 - 2 * t)
        }
    }

    /// How a tile draws against the zone.
    enum TileDraw: Equatable {
        /// Wholly nearer than the zone: geometry alone, no picture.
        case vector
        /// The zone's edge crosses the tile: the pictured groups as
        /// geometry, the picture blended over them, the rest over it.
        case blended
        /// Wholly past the fade: the picture alone stands for its groups.
        case picture
    }

    /// The draw of a tile whose ground square is `originAndSize` (x, y,
    /// side) on the plane z = 0.
    static func tileDraw(span: Span, eye: SIMD3<Float>, tileOriginAndSize: SIMD3<Float>) -> TileDraw {
        let lower = SIMD2<Float>(tileOriginAndSize.x, tileOriginAndSize.y)
        let upper = lower + SIMD2<Float>(repeating: tileOriginAndSize.z)
        let ground = SIMD2<Float>(eye.x, eye.y)
        let nearestPoint = simd_clamp(ground, lower, upper)
        let nearest = simd_length(SIMD3<Float>(nearestPoint.x - ground.x, nearestPoint.y - ground.y, eye.z))
        let farthestOffset = simd_max(simd_abs(lower - ground), simd_abs(upper - ground))
        let farthest = simd_length(SIMD3<Float>(farthestOffset.x, farthestOffset.y, eye.z))
        if farthest <= span.start {
            return .vector
        }
        return nearest >= span.end ? .picture : .blended
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// A dash pattern measured along the route as it appears on screen, so dashes
/// keep their size at any zoom instead of stretching with the geometry.
public struct ImmersiveMapRouteDash: Equatable, Sendable {
    /// Length of the drawn part of one period, in points.
    public var dashPoints: Double
    /// Length of the gap of one period, in points.
    public var gapPoints: Double

    public init(dashPoints: Double, gapPoints: Double) {
        self.dashPoints = dashPoints
        self.gapPoints = gapPoints
    }
}

/// A route drawn over the globe: a great-circle ribbon following an
/// ``ImmersiveMapGeoPath``, lifted off the surface by the path's altitude
/// profile, with a width that stays constant on screen.
///
/// Routes render in the map world pass with depth testing, so the far half of
/// an arc disappears behind the planet and a 3D model in front of the line
/// covers it. Globe presentation only in this version: the route fades out as
/// the globe unfurls into the flat map.
public struct ImmersiveMapRoute: Identifiable, Equatable, Sendable {
    public var id: UInt64
    public var path: ImmersiveMapGeoPath
    /// Straight (non-premultiplied) RGBA.
    public var color: SIMD4<Float>
    /// Line width in points. Sub-point widths stay visible: the line keeps a
    /// one-pixel body and fades its alpha instead of dropping out.
    public var widthPoints: Double
    /// Fraction of the path drawn from the start, `0...1`. Animate it through
    /// `ImmersiveMapRoutesController.setProgress(id:_:duration:)` for a line
    /// that draws itself.
    public var progress: Double
    /// nil draws a solid line.
    public var dash: ImmersiveMapRouteDash?

    public init(id: UInt64,
                path: ImmersiveMapGeoPath,
                color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
                widthPoints: Double = 2,
                progress: Double = 1,
                dash: ImmersiveMapRouteDash? = nil) {
        self.id = id
        self.path = path
        self.color = color
        self.widthPoints = widthPoints
        self.progress = progress
        self.dash = dash
    }
}

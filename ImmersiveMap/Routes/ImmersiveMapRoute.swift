// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

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

    public init(id: UInt64,
                path: ImmersiveMapGeoPath,
                color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
                widthPoints: Double = 2,
                progress: Double = 1) {
        self.id = id
        self.path = path
        self.color = color
        self.widthPoints = widthPoints
        self.progress = progress
    }
}

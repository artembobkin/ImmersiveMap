// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// How much closer the render camera sits to the globe than the zoom alone
/// would put it, so the globe shows the Mercator scale of the view centre.
///
/// A Mercator tile near a pole is `cos(latitude)` times smaller on the
/// sphere than at the equator, in each axis, so at one camera distance the
/// frustum takes `1 / cos^2` times more tiles there (8 times at 70 degrees,
/// 33 at 80). Instead of coarsening the demand near the poles, the camera
/// moves in by the local surface scale (`SurfaceScaleMath`): the frustum
/// then covers the same number of tiles at every latitude, and one zoom
/// shows the same ground area on the globe as on the flat map, which is
/// what the plane shows at that zoom anyway. Through the morph the factor
/// follows the surface's local scale at the view centre, so the picture
/// keeps its scale while the sphere unfurls, and on the plane it is 1.
///
/// The move-in ramps in from `activationZoom` over `activationSpan`: at
/// planet zooms the whole globe is in view and a camera pulled onto a pole
/// would show a fraction of it for nothing.
enum GlobeCameraProximity {
    /// The camera zoom the move-in starts at.
    static let activationZoom: Double = 3
    /// The zoom span over which it ramps to full.
    static let activationSpan: Double = 1

    /// 0 below the activation zoom, 1 a span above it, smooth between.
    static func activation(zoom: Double) -> Double {
        let progress = min(max((zoom - activationZoom) / activationSpan, 0), 1)
        return progress * progress * (3 - 2 * progress)
    }

    /// The factor on the camera's distance to the view centre: the local
    /// surface scale (`cos(latitude)` on the sphere, 1 on the plane, the
    /// morph's curve between) blended in by the activation. Never below
    /// `cos` of the Mercator limit, since the view centre never lies beyond
    /// it.
    static func distanceFactor(latitude: Double, transition: Float, zoom: Double) -> Double {
        let surfaceScale = SurfaceScaleMath.surfaceScale(latitude: latitude, transition: transition)
        return 1 + (surfaceScale - 1) * activation(zoom: zoom)
    }
}

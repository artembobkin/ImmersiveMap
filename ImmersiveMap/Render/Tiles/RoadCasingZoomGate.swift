// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Zoom gate for the road casing: the outline pass under the carriageway
/// fill draws only from street zoom up. Below it the casing is a fraction
/// of a pixel around a line that is itself a pixel or two wide, and what
/// it adds is not an outline but darker, busier lines that shimmer in the
/// far range; the fill alone reads cleaner. A camera-zoom gate, so the
/// casing of every tile in the frame comes and goes together.
enum RoadCasingZoomGate {
    /// The camera zoom from which the casing draws.
    static let minimumZoom: Double = 16

    static func drawsCasing(cameraZoom: Double) -> Bool {
        cameraZoom >= minimumZoom
    }
}

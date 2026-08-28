// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// How the globe surface is painted: from the tile geometry projected onto
/// the sphere (`GlobeVectorSurfaceRenderSubsystem`), or from the raster tile
/// atlas the surface grid samples (`TileAtlasSubsystem`). The atlas path is
/// kept only for the device comparison while the vector path settles and is
/// selected through the launch environment; it is not public API and goes
/// away with the atlas.
enum GlobeSurfaceRenderPath: Equatable {
    case vector
    case atlas

    static let environmentKey = "IMMERSIVEMAP_GLOBE_SURFACE_PATH"

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> GlobeSurfaceRenderPath {
        environment[environmentKey]?.lowercased() == "atlas" ? .atlas : .vector
    }
}

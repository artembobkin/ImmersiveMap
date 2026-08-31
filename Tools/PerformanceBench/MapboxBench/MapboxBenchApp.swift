// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI

/// The Mapbox benchmark host. This binary links only the Mapbox Maps SDK,
/// so its memory footprint and CPU are that SDK's own: ImmersiveMap is not
/// resident in the process. `BENCH_ENGINE` picks a variant:
/// `mapbox-standard` (default), `mapbox-standard-msaa4` (4x MSAA, matching
/// ImmersiveMap's world pass), `mapbox-streets`; the rest of the launch
/// environment is shared with the ImmersiveMap app, see `BenchRootScene`.
@main
struct MapboxBenchApp: App {
    var body: some Scene {
        BenchRootScene(catalog: MapboxEngineCatalog())
    }
}

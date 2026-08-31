// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI

/// The ImmersiveMap benchmark host. This binary links only ImmersiveMap, so
/// its memory footprint and CPU are the engine's own: no second map SDK is
/// resident in the process to blur the numbers. `BENCH_ENGINE` picks a
/// variant: `immersivemap` (default), `immersivemap-noshadows`,
/// `immersivemap-lean`; the rest of the launch environment is shared with
/// the Mapbox app, see `BenchRootScene`.
@main
struct ImmersiveMapBenchApp: App {
    var body: some Scene {
        BenchRootScene(catalog: ImmersiveMapEngineCatalog())
    }
}

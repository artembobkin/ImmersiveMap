// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import UIKit

/// What the harness needs from a map engine: a view to put on screen, an
/// instant camera set, an animated flight, and a per-frame callback.
@MainActor
protocol BenchEngine: AnyObject {
    var name: String { get }
    var version: String { get }
    var view: UIView { get }
    var onFrame: (() -> Void)? { get set }
    func jump(to pose: BenchPose)
    func fly(to pose: BenchPose, duration: TimeInterval, completion: @escaping () -> Void)
}

/// The one seam between the shared harness and an SDK. Each bench app links
/// exactly one engine and hands the harness a catalog of the variants that
/// binary carries, so a run's memory and CPU belong to that engine alone. A
/// name the catalog does not know aborts the run with a BENCH_ERROR line
/// instead of silently measuring the wrong thing.
@MainActor
protocol BenchEngineCatalog {
    var defaultEngineName: String { get }
    /// SDK-level setup that must precede the memory baseline: credentials,
    /// cold-cache clearing. Returns false (after printing a BENCH_ERROR
    /// line) when the run cannot proceed.
    func prepare(engineName: String, coldCache: Bool) async -> Bool
    func makeEngine(named name: String, targetFPS: Int, coldCache: Bool) -> BenchEngine?
}

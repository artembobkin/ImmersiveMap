// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap
import MapboxMaps
import SwiftUI
import UIKit

/// The benchmark host. One launch measures one engine in one cache state and
/// exits; the driver script launches it once per combination and collects
/// the JSON it prints. Launch environment:
///
/// - `BENCH_ENGINE`: `immersivemap` (default), `immersivemap-noshadows`, `immersivemap-lean`,
///   `mapbox-standard`, `mapbox-standard-msaa4` (4x MSAA, matching ImmersiveMap's world pass), `mapbox-streets`
/// - `BENCH_CACHE`: `warm` (default) or `cold` (disk caches cleared before the map is made)
/// - `BENCH_FPS`: display rate to request, default 120
/// - `BENCH_EXIT`: `1` (default) to quit when the run is written
@main
struct ImmersiveMapPerformanceBenchApp: App {
    var body: some Scene {
        WindowGroup {
            BenchRootView()
                .ignoresSafeArea()
                .statusBarHidden()
        }
    }
}

private struct BenchRootView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BenchViewController {
        BenchViewController()
    }

    func updateUIViewController(_ uiViewController: BenchViewController, context: Context) {}
}

@MainActor
final class BenchViewController: UIViewController {
    private var engine: BenchEngine?
    private var metrics: BenchMetrics?
    private var windows: [BenchWindow] = []
    private var memoryAtStart: Double = 0
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // A run is minutes long and unattended; auto-lock would end it.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard started == false else { return }
        started = true
        Task { await run() }
    }

    private func run() async {
        let environment = ProcessInfo.processInfo.environment
        let engineName = environment["BENCH_ENGINE"] ?? "immersivemap"
        let cacheState = environment["BENCH_CACHE"] ?? "warm"
        let targetFPS = Int(environment["BENCH_FPS"] ?? "") ?? 120
        let coldCache = cacheState == "cold"

        memoryAtStart = BenchMetrics.physicalFootprintMB()
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let thermalAtStart = Self.thermalName(ProcessInfo.processInfo.thermalState)

        if engineName.hasPrefix("mapbox") {
            guard let token = BenchSecrets.mapboxAccessToken() else {
                print("BENCH_ERROR no MAPBOX_ACCESS_TOKEN in the environment or LocalSecrets.plist")
                return
            }
            MapboxOptions.accessToken = token
            if coldCache {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    MapboxMap.clearData { _ in continuation.resume() }
                }
            }
        }

        // The measured baseline: the process with the window up and no map.
        try? await Task.sleep(for: .seconds(1))
        let memoryBaseline = BenchMetrics.physicalFootprintMB()

        let engine: BenchEngine
        switch engineName {
        case "mapbox-standard":
            engine = MapboxBenchEngine(targetFPS: targetFPS, style: .standard, styleName: "standard")
        case "mapbox-standard-msaa4":
            engine = MapboxBenchEngine(targetFPS: targetFPS, style: .standard, styleName: "standard", sampleCount: 4)
        case "mapbox-streets":
            engine = MapboxBenchEngine(targetFPS: targetFPS, style: .streets, styleName: "streets")
        default:
            let variant = ImmersiveMapBenchEngine.Variant(rawValue: engineName) ?? .standard
            engine = ImmersiveMapBenchEngine(targetFPS: targetFPS, coldCache: coldCache, variant: variant)
        }
        self.engine = engine

        let metrics = BenchMetrics(targetFPS: targetFPS)
        self.metrics = metrics
        engine.onFrame = { [weak metrics] in metrics?.noteEngineFrame() }

        engine.view.frame = view.bounds
        engine.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(engine.view)
        engine.jump(to: BenchScenario.establish)
        metrics.start()

        // Warm-up is measured too, as its own window: it is where style and
        // first tiles arrive, so its CPU and memory say what opening costs.
        metrics.beginWindow()
        try? await Task.sleep(for: .seconds(BenchScenario.warmUp))
        windows.append(metrics.endWindow(name: "warmup"))

        // Tour: one window per shot (flight plus hold), and the whole tour.
        var tourWindows: [BenchWindow] = []
        for shot in BenchScenario.tour {
            metrics.beginWindow()
            await fly(engine, to: shot.pose, duration: shot.duration)
            if shot.holdAfter > 0 {
                try? await Task.sleep(for: .seconds(shot.holdAfter))
            }
            tourWindows.append(metrics.endWindow(name: "tour.\(shot.name)"))
        }
        windows.append(contentsOf: tourWindows)
        windows.append(Self.combine(tourWindows, name: "tour"))

        // Pan: the camera is set from every host tick.
        engine.jump(to: BenchScenario.panStart)
        try? await Task.sleep(for: .seconds(2))
        let panStart = CACurrentMediaTime()
        metrics.onTick = { [weak engine] now in
            let progress = (now - panStart) / BenchScenario.panDuration
            guard progress <= 1 else { return }
            engine?.jump(to: BenchScenario.panPose(progress: progress))
        }
        metrics.beginWindow()
        try? await Task.sleep(for: .seconds(BenchScenario.panDuration))
        windows.append(metrics.endWindow(name: "pan"))
        metrics.onTick = nil

        // Idle: settle, then measure a still map.
        try? await Task.sleep(for: .seconds(BenchScenario.idleSettle))
        metrics.beginWindow()
        try? await Task.sleep(for: .seconds(BenchScenario.idleDuration))
        windows.append(metrics.endWindow(name: "idle"))

        metrics.stop()

        let screen = view.window?.windowScene?.screen
        let result = BenchResult(engine: engine.name,
                                 engineVersion: engine.version,
                                 cacheState: cacheState,
                                 device: Self.deviceModel(),
                                 systemVersion: UIDevice.current.systemVersion,
                                 screenScale: Double(screen?.scale ?? 0),
                                 viewSizePoints: [Double(view.bounds.width), Double(view.bounds.height)],
                                 targetFramesPerSecond: targetFPS,
                                 startedAt: startedAt,
                                 lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                 thermalStateAtStart: thermalAtStart,
                                 thermalStateAtEnd: Self.thermalName(ProcessInfo.processInfo.thermalState),
                                 memoryAtStartMB: memoryAtStart,
                                 memoryBaselineMB: memoryBaseline,
                                 windows: windows)
        BenchOutput.write(result)

        if (environment["BENCH_EXIT"] ?? "1") == "1" {
            try? await Task.sleep(for: .seconds(1))
            exit(0)
        }
    }

    private func fly(_ engine: BenchEngine, to pose: BenchPose, duration: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            engine.fly(to: pose, duration: duration) {
                guard resumed == false else { return }
                resumed = true
                continuation.resume()
            }
        }
    }

    /// Sums the tour's shot windows into one: tick and frame counts add up,
    /// percentiles are approximated by the duration-weighted mean of the
    /// shots' own, and peaks are the maximum over shots.
    private static func combine(_ parts: [BenchWindow], name: String) -> BenchWindow {
        let duration = parts.reduce(0) { $0 + $1.durationSeconds }
        func weighted(_ key: (BenchWindow) -> Double) -> Double {
            guard duration > 0 else { return 0 }
            return parts.reduce(0) { $0 + key($1) * $1.durationSeconds } / duration
        }
        let ticks = parts.reduce(0) { $0 + $1.hostTicks }
        let frames = parts.reduce(0) { $0 + $1.engineFrames }
        return BenchWindow(name: name,
                           durationSeconds: duration,
                           hostTicks: ticks,
                           hostTicksPerSecond: duration > 0 ? Double(ticks) / duration : 0,
                           hostIntervalMedianMs: weighted { $0.hostIntervalMedianMs },
                           hostIntervalP95Ms: weighted { $0.hostIntervalP95Ms },
                           hostIntervalP99Ms: weighted { $0.hostIntervalP99Ms },
                           hostIntervalMaxMs: parts.map(\.hostIntervalMaxMs).max() ?? 0,
                           hostHitches: parts.reduce(0) { $0 + $1.hostHitches },
                           hostHitchTimeMs: parts.reduce(0) { $0 + $1.hostHitchTimeMs },
                           engineFrames: frames,
                           engineFramesPerSecond: duration > 0 ? Double(frames) / duration : 0,
                           cpuAveragePercent: weighted { $0.cpuAveragePercent },
                           cpuPeakPercent: parts.map(\.cpuPeakPercent).max() ?? 0,
                           mainThreadBusyAveragePercent: weighted { $0.mainThreadBusyAveragePercent },
                           mainThreadBusyPeakPercent: parts.map(\.mainThreadBusyPeakPercent).max() ?? 0,
                           memoryAverageMB: weighted { $0.memoryAverageMB },
                           memoryPeakMB: parts.map(\.memoryPeakMB).max() ?? 0)
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }
}

// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

/// The shared scene of both bench apps: a full-screen host around the
/// measuring controller. One launch measures one engine variant in one cache
/// state and exits; the driver script launches the app once per combination
/// and collects the JSON it prints. Launch environment:
///
/// - `BENCH_ENGINE`: a variant from the app's catalog (see each app's doc)
/// - `BENCH_SCENARIO`: `full` (default) or `globe` (the sphere only, see BenchScenario)
/// - `BENCH_CACHE`: `warm` (default) or `cold` (disk caches cleared before the map is made)
/// - `BENCH_FPS`: display rate to request, default 120
/// - `BENCH_EXIT`: `1` (default) to quit when the run is written
struct BenchRootScene: Scene {
    let catalog: BenchEngineCatalog

    var body: some Scene {
        WindowGroup {
            BenchRootView(catalog: catalog)
                .ignoresSafeArea()
                .statusBarHidden()
        }
    }
}

private struct BenchRootView: UIViewControllerRepresentable {
    let catalog: BenchEngineCatalog

    func makeUIViewController(context: Context) -> BenchViewController {
        BenchViewController(catalog: catalog)
    }

    func updateUIViewController(_ uiViewController: BenchViewController, context: Context) {}
}

@MainActor
final class BenchViewController: UIViewController {
    private let catalog: BenchEngineCatalog
    private var engine: BenchEngine?
    private var metrics: BenchMetrics?
    private var windows: [BenchWindow] = []
    private var memoryAtStart: Double = 0
    private var started = false

    init(catalog: BenchEngineCatalog) {
        self.catalog = catalog
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("BenchViewController is code-only")
    }

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
        let engineName = environment["BENCH_ENGINE"] ?? catalog.defaultEngineName
        let cacheState = environment["BENCH_CACHE"] ?? "warm"
        let targetFPS = Int(environment["BENCH_FPS"] ?? "") ?? 120
        let coldCache = cacheState == "cold"
        let scenarioName = environment["BENCH_SCENARIO"] ?? "full"
        guard let scenario = BenchScenario.script(named: scenarioName) else {
            print("BENCH_ERROR scenario \(scenarioName) does not exist")
            return
        }

        memoryAtStart = BenchMetrics.physicalFootprintMB()
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let thermalAtStart = Self.thermalName(ProcessInfo.processInfo.thermalState)

        guard await catalog.prepare(engineName: engineName, coldCache: coldCache) else {
            return
        }

        // The measured baseline: the process with the window up and no map.
        try? await Task.sleep(for: .seconds(1))
        let memoryBaseline = BenchMetrics.physicalFootprintMB()

        guard let engine = catalog.makeEngine(named: engineName,
                                              targetFPS: targetFPS,
                                              coldCache: coldCache) else {
            print("BENCH_ERROR engine \(engineName) does not exist in this binary")
            return
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
        try? await Task.sleep(for: .seconds(scenario.warmUp))
        windows.append(metrics.endWindow(name: "warmup"))

        // Tour: one window per shot (flight plus hold), and the whole tour.
        var tourWindows: [BenchWindow] = []
        for shot in scenario.tour {
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
        engine.jump(to: scenario.panStart)
        try? await Task.sleep(for: .seconds(2))
        let panStart = CACurrentMediaTime()
        metrics.onTick = { [weak engine] now in
            let progress = (now - panStart) / scenario.panDuration
            guard progress <= 1 else { return }
            engine?.jump(to: scenario.panPose(progress))
        }
        metrics.beginWindow()
        try? await Task.sleep(for: .seconds(scenario.panDuration))
        windows.append(metrics.endWindow(name: "pan"))
        metrics.onTick = nil

        // Idle: settle, then measure a still map.
        try? await Task.sleep(for: .seconds(scenario.idleSettle))
        metrics.beginWindow()
        try? await Task.sleep(for: .seconds(scenario.idleDuration))
        windows.append(metrics.endWindow(name: "idle"))

        metrics.stop()

        let screen = view.window?.windowScene?.screen
        let result = BenchResult(engine: engine.name,
                                 engineVersion: engine.version,
                                 cacheState: cacheState,
                                 scenario: scenario.name,
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

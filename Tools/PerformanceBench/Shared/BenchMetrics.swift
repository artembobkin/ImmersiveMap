// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import QuartzCore
import UIKit

/// One measured window of a run. Everything is host-side: a display link on
/// the main thread (whose cadence says whether the engine's main-thread work
/// keeps up with the display), process CPU time, and the physical memory
/// footprint. Engine frames are whatever per-frame callback the engine
/// exposes, counted rather than timed.
struct BenchWindow: Codable {
    var name: String
    var durationSeconds: Double

    var hostTicks: Int
    var hostTicksPerSecond: Double
    var hostIntervalMedianMs: Double
    var hostIntervalP95Ms: Double
    var hostIntervalP99Ms: Double
    var hostIntervalMaxMs: Double
    /// Ticks that arrived two or more vsyncs late at the requested rate.
    var hostHitches: Int
    /// Time the display spent inside those late ticks, past the first vsync.
    var hostHitchTimeMs: Double

    var engineFrames: Int
    var engineFramesPerSecond: Double

    var cpuAveragePercent: Double
    var cpuPeakPercent: Double
    /// CPU time of the main thread alone over wall time: near 100 means the
    /// engine's frame is CPU-bound on main, well below it while the cadence
    /// still drops means main is waiting (GPU, a semaphore, I/O).
    var mainThreadBusyAveragePercent: Double
    var mainThreadBusyPeakPercent: Double
    var memoryAverageMB: Double
    var memoryPeakMB: Double
}

struct BenchResult: Codable {
    var engine: String
    var engineVersion: String
    var cacheState: String
    var scenario: String
    var device: String
    var systemVersion: String
    var screenScale: Double
    var viewSizePoints: [Double]
    var targetFramesPerSecond: Int
    var startedAt: String
    var lowPowerMode: Bool
    var thermalStateAtStart: String
    var thermalStateAtEnd: String
    var memoryAtStartMB: Double
    var memoryBaselineMB: Double
    var windows: [BenchWindow]
}

final class BenchMetrics {
    private(set) var isRecording = false

    private var displayLink: CADisplayLink?
    private var sampler: Timer?
    private let targetFPS: Int

    private var tickTimestamps: [CFTimeInterval] = []
    private var engineFrameCount = 0
    private var cpuSamples: [Double] = []
    private var mainBusySamples: [Double] = []
    private var memorySamples: [Double] = []
    private var lastMainCPUTime: Double = 0
    private let mainThread = mach_thread_self()
    private var windowStart: CFTimeInterval = 0
    private var lastCPUTime: Double = 0
    private var lastCPUWall: CFTimeInterval = 0

    /// Called on every host tick while recording; the pan scenario drives the
    /// camera from it.
    var onTick: ((CFTimeInterval) -> Void)?

    init(targetFPS: Int) {
        self.targetFPS = targetFPS
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(targetFPS),
                                                        maximum: Float(targetFPS),
                                                        preferred: Float(targetFPS))
        link.add(to: .main, forMode: .common)
        displayLink = link
        sampler = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    func beginWindow() {
        tickTimestamps.removeAll(keepingCapacity: true)
        engineFrameCount = 0
        cpuSamples.removeAll(keepingCapacity: true)
        mainBusySamples.removeAll(keepingCapacity: true)
        memorySamples.removeAll(keepingCapacity: true)
        windowStart = CACurrentMediaTime()
        lastCPUTime = Self.processCPUSeconds()
        lastMainCPUTime = Self.threadCPUSeconds(mainThread)
        lastCPUWall = windowStart
        isRecording = true
    }

    func endWindow(name: String) -> BenchWindow {
        isRecording = false
        let end = CACurrentMediaTime()
        let duration = end - windowStart

        var intervals: [Double] = []
        intervals.reserveCapacity(tickTimestamps.count)
        for i in 1..<max(tickTimestamps.count, 1) {
            intervals.append((tickTimestamps[i] - tickTimestamps[i - 1]) * 1000)
        }
        let sorted = intervals.sorted()
        let vsyncMs = 1000.0 / Double(targetFPS)
        let lateThreshold = vsyncMs * 2 - 0.5
        let late = intervals.filter { $0 >= lateThreshold }

        func percentile(_ p: Double) -> Double {
            guard sorted.isEmpty == false else { return 0 }
            let index = Int((Double(sorted.count - 1) * p).rounded())
            return sorted[min(max(index, 0), sorted.count - 1)]
        }

        return BenchWindow(
            name: name,
            durationSeconds: duration,
            hostTicks: tickTimestamps.count,
            hostTicksPerSecond: duration > 0 ? Double(tickTimestamps.count) / duration : 0,
            hostIntervalMedianMs: percentile(0.5),
            hostIntervalP95Ms: percentile(0.95),
            hostIntervalP99Ms: percentile(0.99),
            hostIntervalMaxMs: sorted.last ?? 0,
            hostHitches: late.count,
            hostHitchTimeMs: late.reduce(0) { $0 + ($1 - vsyncMs) },
            engineFrames: engineFrameCount,
            engineFramesPerSecond: duration > 0 ? Double(engineFrameCount) / duration : 0,
            cpuAveragePercent: cpuSamples.isEmpty ? 0 : cpuSamples.reduce(0, +) / Double(cpuSamples.count),
            cpuPeakPercent: cpuSamples.max() ?? 0,
            mainThreadBusyAveragePercent: mainBusySamples.isEmpty ? 0 : mainBusySamples.reduce(0, +) / Double(mainBusySamples.count),
            mainThreadBusyPeakPercent: mainBusySamples.max() ?? 0,
            memoryAverageMB: memorySamples.isEmpty ? 0 : memorySamples.reduce(0, +) / Double(memorySamples.count),
            memoryPeakMB: memorySamples.max() ?? 0
        )
    }

    func noteEngineFrame() {
        guard isRecording else { return }
        engineFrameCount += 1
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        sampler?.invalidate()
        sampler = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        if isRecording {
            tickTimestamps.append(link.timestamp)
        }
        onTick?(link.timestamp)
    }

    private func sample() {
        guard isRecording else { return }
        let now = CACurrentMediaTime()
        let cpu = Self.processCPUSeconds()
        let wall = now - lastCPUWall
        let mainCPU = Self.threadCPUSeconds(mainThread)
        if wall > 0 {
            cpuSamples.append((cpu - lastCPUTime) / wall * 100)
            mainBusySamples.append((mainCPU - lastMainCPUTime) / wall * 100)
        }
        lastCPUTime = cpu
        lastMainCPUTime = mainCPU
        lastCPUWall = now
        memorySamples.append(Self.physicalFootprintMB())
    }

    // MARK: - Process counters

    /// User plus system CPU time of the whole process, all threads.
    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    /// User plus system CPU time of one thread.
    static func threadCPUSeconds(_ thread: thread_t) -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        return user + system
    }

    /// `phys_footprint`, the number Xcode's memory gauge and jetsam use.
    static func physicalFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}

enum BenchOutput {
    static func write(_ result: BenchResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) else {
            print("BENCH_ERROR could not encode the result")
            return
        }
        let name = "bench-\(result.engine)-\(result.cacheState).json"
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: documents.appendingPathComponent(name))
        }
        print("BENCH_RESULT_BEGIN \(name)")
        print(text)
        print("BENCH_RESULT_END")
    }
}
